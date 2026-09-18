import XCTest
@testable import TriageBedrock
@testable import TriageCore

/// Does the new prompt produce the keep carve-outs the user had to make by hand?
///
/// SKIPS unless `TRIAGE_LIVE_BEDROCK=1`, like the other live tests, because it calls a real model.
///
///     TRIAGE_LIVE_BEDROCK=1 swift test --disable-sandbox --filter KeepCarveOutCoverageTests
///
/// Ground truth is eight messages the user rescued by hand from senders the model itself called
/// promotional. Against the previous prompt its own keepSubjects covered exactly ONE of the eight:
/// it found strike notices and timetables for the rail operator and missed a price change to the
/// product the user pays for. That 1/8 is the number this has to beat.
final class KeepCarveOutCoverageTests: XCTestCase {

    private var isLive: Bool {
        ProcessInfo.processInfo.environment["TRIAGE_LIVE_BEDROCK"] == "1"
    }

    private func load(_ path: String) -> [(String, String)] {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return raw.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: "<|>")
            guard f.count >= 2 else { return nil }
            return (f[0], f[1])
        }
    }

    func testCarveOutCoverage() async throws {
        try XCTSkipUnless(isLive, "Set TRIAGE_LIVE_BEDROCK=1 to exercise real Bedrock.")

        let subjectRows = load("/Users/opjha/.kiro/crew/scratch/runtime-69cf3966/carve_subjects.txt")
        let truthRows = load("/Users/opjha/.kiro/crew/scratch/runtime-69cf3966/carve_truth.txt")
        try XCTSkipIf(subjectRows.isEmpty, "No exported subjects to measure against.")

        // Group the real subjects by sender, newest first as exported.
        var bySender: [String: [String]] = [:]
        for (sender, subject) in subjectRows { bySender[sender, default: []].append(subject) }

        let requests = bySender.map { sender, subjects -> SenderClassificationRequest in
            // Sampled ACROSS the sender's history, not the newest N.
            //
            // A newest-first slice was the first version of this and it is the same mistake the app
            // itself had already fixed: the rail operator's newest forty subjects were all one
            // season's campaign, so the one price-change notice in a hundred and eight messages was
            // never shown to the model, and its absence from the answer was scored as the model's
            // failure rather than the harness's.
            let cap = 40
            let sampled: [String]
            if subjects.count <= cap {
                sampled = subjects
            } else {
                let stride = Double(subjects.count) / Double(cap)
                sampled = (0..<cap).map { subjects[Int(Double($0) * stride)] }
            }
            return SenderClassificationRequest(
                senderEmail: sender,
                displayName: sender,
                sampleSubjects: sampled,
                totalEmails: subjects.count,
                hasUnsubscribe: true,
                averageIntervalDays: nil
            )
        }

        let transport = BedrockLLMTransport(
            modelId: ProcessInfo.processInfo.environment["TRIAGE_LIVE_MODEL"]
                ?? BedrockLLMTransport.defaultModelId
        )
        let verdicts = try await transport.classify(senders: requests)

        var keepBySender: [String: [String]] = [:]
        var sampledBySender: [String: [String]] = [:]
        for request in requests { sampledBySender[request.senderEmail.lowercased()] = request.sampleSubjects }
        for v in verdicts {
            keepBySender[v.senderEmail.lowercased()] = v.keepSubjects
            print("CARVE \(v.senderEmail) category=\(v.category.rawValue) unsure=\(v.isUnsure) keep=\(v.keepSubjects) disposable=\(v.disposableSubjects)")
        }

        // Coverage: for each message the user rescued, does any keep fragment match it?
        // A whole-sender exception counts as covered only if the model produced ANY keep fragment,
        // since there is no single subject to match against.
        var covered = 0
        var missedButUnseen = 0
        for (sender, truth) in truthRows {
            let fragments = keepBySender[sender] ?? []
            let isCovered: Bool
            if truth == "*WHOLE*" {
                isCovered = !fragments.isEmpty
            } else {
                isCovered = fragments.contains { SubjectStem.pattern($0, matches: truth) }
                    || fragments.contains { truth.lowercased().contains($0.lowercased()) }
            }
            if isCovered { covered += 1 }

            // Was the model even shown a message of this kind? A fragment it could not have derived
            // is a sampling gap, not a judgement failure, and scoring the two the same way would
            // blame the model for the harness.
            let wasShown = truth == "*WHOLE*"
                || (sampledBySender[sender] ?? []).contains { SubjectStem.pattern(truth, matches: $0) }
            if !isCovered && !wasShown { missedButUnseen += 1 }

            print("CARVE \(isCovered ? "COVERED " : (wasShown ? "MISSED  " : "UNSEEN  ")) \(sender) | needs=\(truth) | model=\(fragments)")
        }

        print("CARVE COVERAGE \(covered)/\(truthRows.count) (previous prompt: 1/8), of the misses \(missedButUnseen) were never sampled")
        XCTAssertGreaterThan(covered, 1, "the new prompt must beat the 1/8 the old one managed")
    }
}
