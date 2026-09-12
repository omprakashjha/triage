import AWSBedrockRuntime
import Foundation
import Smithy
import TriageCore

/// The real transport: signs and sends a Bedrock Converse call via the AWS SDK.
///
/// This file is the ONLY place in Triage that imports the AWS SDK. The prompt, the
/// schema, the response parsing and every safety rule live in `TriageCore` as pure
/// code, so the test suite never links this.
///
/// Credentials come from the SDK's default resolver chain, which is the reason to use
/// the SDK rather than hand-rolling SigV4: it handles the SSO token cache,
/// `credential_process`, environment variables and refresh. Reimplementing that
/// correctly is the hard part, not the HTTP call.
public struct BedrockLLMTransport: LLMTransport {

    public let modelId: String
    public let promptVersion: String
    /// `nil` means "whatever the AWS profile says".
    ///
    /// Passing an explicit region SILENTLY OVERRIDES the region in the user's profile.
    /// A default belongs in the profile, not here.
    public let region: String?
    public let maxTokens: Int

    public init(
        modelId: String = BedrockLLMTransport.defaultModelId,
        region: String? = nil,
        promptVersion: String = SenderClassificationPrompt.version,
        maxTokens: Int = 4096
    ) {
        self.modelId = modelId
        self.region = region
        self.promptVersion = promptVersion
        self.maxTokens = maxTokens
    }

    /// The model used when the user has not named one.
    ///
    /// Configurable because model availability differs by account and region.
    ///
    /// The progression is worth recording, because each step was driven by observed output
    /// rather than by assuming a bigger model is better:
    ///
    /// - Haiku 4.5 first, on the belief — stated in a comment here that has now been deleted
    ///   as wrong — that sender classification is a labelling task rather than a reasoning
    ///   one. It is not. The mail is multilingual, senders are mixed, and the job includes
    ///   WRITING generalising subject rules. Haiku's observable failure was echoing whole
    ///   subject lines back as "patterns", which left 59 emails on a real mailbox matching no
    ///   pattern at all.
    /// - Sonnet 4.5 fixed exactly that: fragments became real generalising words in the
    ///   sender's own language, and abstentions halved from 59 to 29.
    /// - Opus 5 now, for the remaining judgement calls — chiefly mixed senders whose split
    ///   must be inferred from twenty subjects in a language the rules cannot read.
    ///
    /// The cost argument never applied. Classification is per SENDER, not per message, and
    /// verdicts are cached by model AND prompt version, so a 12,000-email mailbox needed
    /// fewer than 100 verdicts in total, once. That cache key also makes an A/B comparison
    /// free: switching model re-requests the senders instead of reusing another model's
    /// answers, and the previous model's verdicts stay in the table beside the new ones.
    ///
    /// `us.` rather than `global.` is deliberate: global routing can leave the US region set,
    /// and this request carries the user's email metadata.
    ///
    /// Note that Opus 5 rejects `temperature` outright. The transport already retries without
    /// it, so this default depends on that path rather than assuming it is unused.
    public static let defaultModelId = "us.anthropic.claude-opus-5"

    public func classify(
        senders: [SenderClassificationRequest],
        corrections: [CorrectionExample]
    ) async throws -> [SenderVerdict] {
        guard !senders.isEmpty else { return [] }

        let client: BedrockRuntimeClient
        do {
            let config = try await BedrockRuntimeClient
                .BedrockRuntimeClientConfiguration(region: region)
            client = BedrockRuntimeClient(config: config)
        } catch {
            // Almost always no resolvable credentials. Say so in terms the user can act
            // on rather than surfacing an SDK error type.
            throw BedrockTransportError.credentialsUnavailable
        }

        let payload: JSONValue
        do {
            payload = try await send(
                client,
                systemPrompt: SenderClassificationPrompt.systemPrompt(corrections: corrections),
                userMessage: SenderClassificationPrompt.userMessage(for: senders),
                schema: SenderClassificationPrompt.outputSchema,
                toolName: SenderClassificationPrompt.toolName,
                toolDescription: SenderClassificationPrompt.toolDescription,
                includeTemperature: true
            )
        } catch BedrockTransportError.temperatureRejected {
            // Some newer models reject `temperature` outright (Opus 5 among them).
            // Retry once without it rather than making the user discover this per model.
            payload = try await send(
                client,
                systemPrompt: SenderClassificationPrompt.systemPrompt(corrections: corrections),
                userMessage: SenderClassificationPrompt.userMessage(for: senders),
                schema: SenderClassificationPrompt.outputSchema,
                toolName: SenderClassificationPrompt.toolName,
                toolDescription: SenderClassificationPrompt.toolDescription,
                includeTemperature: false
            )
        }

        return SenderClassificationPrompt.parseVerdicts(from: payload)
    }

    /// Classify individual messages the sender pass could not decide.
    public func classify(
        messages: [MessageClassificationRequest],
        corrections: [CorrectionExample]
    ) async throws -> [MessageVerdict] {
        guard !messages.isEmpty else { return [] }

        let client: BedrockRuntimeClient
        do {
            let config = try await BedrockRuntimeClient
                .BedrockRuntimeClientConfiguration(region: region)
            client = BedrockRuntimeClient(config: config)
        } catch {
            throw BedrockTransportError.credentialsUnavailable
        }

        let system = MessageClassificationPrompt.systemPrompt(corrections: corrections)
        let body = MessageClassificationPrompt.userMessage(for: messages)

        let payload: JSONValue
        do {
            payload = try await send(
                client,
                systemPrompt: system,
                userMessage: body,
                schema: MessageClassificationPrompt.outputSchema,
                toolName: MessageClassificationPrompt.toolName,
                toolDescription: MessageClassificationPrompt.toolDescription,
                includeTemperature: true
            )
        } catch BedrockTransportError.temperatureRejected {
            payload = try await send(
                client,
                systemPrompt: system,
                userMessage: body,
                schema: MessageClassificationPrompt.outputSchema,
                toolName: MessageClassificationPrompt.toolName,
                toolDescription: MessageClassificationPrompt.toolDescription,
                includeTemperature: false
            )
        }

        return MessageClassificationPrompt.parseVerdicts(from: payload)
    }

    /// One request shape for both passes.
    ///
    /// Generalised rather than copied: every Bedrock failure mode worth translating - access
    /// denied, model not found, throttling, the temperature rejection newer models need, and
    /// credential resolution that only surfaces on the CALL - is handled here. A second
    /// prompt with its own copy of that would drift, and the drift would show up as an
    /// unhelpful error at the worst moment.
    private func send(
        _ client: BedrockRuntimeClient,
        systemPrompt: String,
        userMessage: String,
        schema: JSONValue,
        toolName: String,
        toolDescription: String,
        includeTemperature: Bool
    ) async throws -> JSONValue {
        let tool = BedrockRuntimeClientTypes.Tool.toolspec(
            BedrockRuntimeClientTypes.ToolSpecification(
                description: toolDescription,
                inputSchema: .json(schema.smithyDocument),
                name: toolName
            )
        )

        let input = ConverseInput(
            inferenceConfig: BedrockRuntimeClientTypes.InferenceConfiguration(
                maxTokens: maxTokens,
                // Temperature 0: classification should be reproducible, and a cached
                // verdict must not depend on which sample the model happened to draw.
                temperature: includeTemperature ? 0 : nil
            ),
            messages: [
                BedrockRuntimeClientTypes.Message(
                    content: [.text(userMessage)],
                    role: .user
                )
            ],
            modelId: modelId,
            system: [.text(systemPrompt)],
            toolConfig: BedrockRuntimeClientTypes.ToolConfiguration(
                // Forced: prose instead of a tool call would mean parsing free text into
                // a decision that sets a safety tier.
                toolChoice: .tool(
                    BedrockRuntimeClientTypes.SpecificToolChoice(name: toolName)
                ),
                tools: [tool]
            )
        )

        let output: ConverseOutput
        do {
            output = try await client.converse(input: input)
        } catch let error as AWSBedrockRuntime.AccessDeniedException {
            throw BedrockTransportError.modelUnavailable(
                "access denied for \(modelId) in \(region ?? "your profile's region") — "
                    + "enable model access in the Bedrock console: \(error.message ?? "no detail")"
            )
        } catch let error as AWSBedrockRuntime.ResourceNotFoundException {
            throw BedrockTransportError.modelUnavailable(
                "\(modelId) not found in \(region ?? "your profile's region"): \(error.message ?? "")"
            )
        } catch let error as AWSBedrockRuntime.ThrottlingException {
            throw BedrockTransportError.throttled(error.message ?? "")
        } catch let error as AWSBedrockRuntime.ValidationException {
            let message = error.message ?? ""
            if includeTemperature, message.localizedCaseInsensitiveContains("temperature") {
                throw BedrockTransportError.temperatureRejected
            }
            throw BedrockTransportError.modelUnavailable("request rejected: \(message)")
        } catch {
            // Credential resolution happens on the CALL, not on client construction, so
            // this is where a missing or expired profile actually surfaces. Translate it
            // into the one instruction the user can act on.
            let text = "\(error)"
            if text.contains("failedToResolveAWSCredentials")
                || text.localizedCaseInsensitiveContains("failed to resolve credentials") {
                throw BedrockTransportError.credentialsUnavailable
            }
            throw BedrockTransportError.modelUnavailable(text)
        }

        return try Self.toolInput(from: output, expecting: toolName)
    }

    /// Pulls the forced tool call out of the response.
    static func toolInput(from output: ConverseOutput, expecting name: String) throws -> JSONValue {
        guard case .message(let message)? = output.output else {
            throw BedrockTransportError.modelUnavailable("response contained no message")
        }
        for block in message.content ?? [] {
            guard case .tooluse(let use) = block else { continue }
            guard use.name == name, let document = use.input else { continue }
            return JSONValue(smithy: document)
        }
        // The model answered in prose despite toolChoice forcing the tool, which means
        // the schema was rejected or the model does not support forcing.
        throw BedrockTransportError.modelUnavailable("no tool call named \(name) in response")
    }
}

// MARK: - Errors

public enum BedrockTransportError: LocalizedError, Sendable {
    case credentialsUnavailable
    case modelUnavailable(String)
    case throttled(String)
    /// Internal control flow for the no-temperature retry.
    case temperatureRejected

    public var errorDescription: String? {
        switch self {
        case .credentialsUnavailable:
            return "No AWS credentials available. Run `aws sso login` in Terminal. "
                + "Note that an app launched from Finder cannot see AWS_PROFILE, so the "
                + "profile must be named `default`."
        case .modelUnavailable(let detail):
            return "Bedrock model unavailable: \(detail)"
        case .throttled(let detail):
            return "Bedrock throttled the request: \(detail)"
        case .temperatureRejected:
            return "The model rejected the temperature parameter."
        }
    }
}
