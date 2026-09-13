import SwiftUI
import TriageCore

/// An email row that can be dragged sideways to decide it.
///
/// Written by hand rather than with `.swipeActions`, which did nothing on this machine. That
/// modifier is documented as available on macOS, but what it listens for is a two-finger trackpad
/// swipe — a SCROLL event, not a gesture — so with a mouse, or a trackpad the system reports
/// differently, there is nothing for it to hear and it silently never fires. There is no error and
/// no fallback; the actions simply do not exist. A `DragGesture` responds to press-and-drag, which
/// every pointing device produces.
///
/// Doing it by hand also buys what the modifier could not. The row follows the pointer and names
/// the action it is about to take before it is committed, so the gesture is learned by trying it
/// and can be abandoned halfway by dragging back — which matters when the actions decide the fate
/// of mail in bulk.
struct SwipeableEmailRow: View {
    let email: EmailMetadata
    let showsHoverActions: Bool
    let onKeep: () -> Void
    let onDelete: () -> Void
    let onEdit: () -> Void

    /// How far the row must travel before letting go commits the action. Far enough that a
    /// stray movement while clicking cannot decide an email, short enough to be one flick.
    private let commitThreshold: CGFloat = 80

    @State private var dragX: CGFloat = 0
    @State private var isCommitting = false

    /// Right is keep, left is delete — matching the colour and icon revealed behind the row.
    private var pendingAction: (label: String, icon: String, color: Color, isKeep: Bool)? {
        if dragX > 12 { return ("Keep", "lock.shield", .green, true) }
        if dragX < -12 { return ("Safe to delete", "trash", .orange, false) }
        return nil
    }

    private var isPastThreshold: Bool { abs(dragX) >= commitThreshold }

    var body: some View {
        ZStack {
            if let action = pendingAction {
                actionBackdrop(action)
            }

            content
                .background(Color(nsColor: .controlBackgroundColor).opacity(dragX == 0 ? 0 : 1))
                .offset(x: dragX)
                .gesture(dragGesture)
        }
        .opacity(isCommitting ? 0.35 : 1)
        // Transient gesture state must never outlive the email it belongs to. A List reuses row
        // state across a diff, so without this a row that has just been decided hands its offset
        // and dimming to whichever email slides into its place.
        .onChange(of: email.messageId) { _, _ in
            dragX = 0
            isCommitting = false
        }
    }

    // MARK: - Gesture

    private var dragGesture: some Gesture {
        // A minimum distance means a click still selects the row: the gesture only takes over
        // once the pointer has actually travelled. On macOS the List scrolls from scroll-wheel
        // and trackpad scroll events rather than from drags, so this cannot eat scrolling.
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard !isCommitting else { return }
                // Horizontal intent only, so a diagonal drag does not decide an email.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragX = value.translation.width
            }
            .onEnded { value in
                guard !isCommitting else { return }
                let travelled = value.translation.width
                guard abs(travelled) >= commitThreshold,
                      abs(travelled) > abs(value.translation.height) else {
                    // Not far enough: spring back and change nothing. Abandoning mid-drag has
                    // to be possible, because these actions apply in bulk.
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { dragX = 0 }
                    return
                }
                commit(keep: travelled > 0)
            }
    }

    private func commit(keep: Bool) {
        isCommitting = true
        // Carry the row off the edge it was dragged toward, so the decision is visibly taken
        // rather than the row merely vanishing on the next reload.
        withAnimation(.easeOut(duration: 0.18)) { dragX = keep ? 400 : -400 }
        if keep { onKeep() } else { onDelete() }

        // Then return it to rest, unconditionally.
        //
        // Leaving the row parked at the edge assumed the decision always removes it from the
        // list, and that is false in two ways. Deciding mail in the SAFE tier to be deletable
        // leaves it in the safe tier, so the row stays — parked offscreen forever. And when the
        // reload does shorten the list, SwiftUI reuses row state across the diff, so a shifted
        // row inherits this offset and dims itself while showing a different email. Both present
        // as a row stuck halfway that comes right only after navigating away, because leaving the
        // screen rebuilds the view and discards the state.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            dragX = 0
            isCommitting = false
        }
    }

    // MARK: - Pieces

    /// The action revealed behind the row, which brightens once the drag would commit.
    private func actionBackdrop(_ action: (label: String, icon: String, color: Color, isKeep: Bool)) -> some View {
        HStack {
            if !action.isKeep { Spacer() }
            Label(action.label, systemImage: action.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
            if action.isKeep { Spacer() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(action.color.opacity(isPastThreshold ? 1 : 0.45))
        .overlay(alignment: action.isKeep ? .trailing : .leading) {
            // Says what letting go will do, so the threshold is not something to guess at.
            Text(isPastThreshold ? "release" : "keep dragging")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(email.subject)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(email.senderEmail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let category = email.category {
                        Text(category.displayName)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Text(email.date, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                // The engine's justification, which is what lets a decision be made from the row
                // instead of by opening something.
                HStack(spacing: 6) {
                    Text(email.categoryReason ?? "—")
                        .font(.caption2)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                    if let confidence = email.categoryConfidence {
                        ConfidenceBadge(confidence: confidence)
                    }
                }
            }

            Spacer(minLength: 0)

            // Always present, only visible on hover, so the row does not change height as the
            // pointer crosses it — and so the actions are discoverable without knowing the
            // gesture exists.
            HStack(spacing: 4) {
                Button(action: onKeep) { Image(systemName: "lock.shield") }
                    .buttonStyle(.borderless)
                    .help("Keep this and its repeats (K)")
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Mark this and its repeats safe to delete (D)")
                Button(action: onEdit) { Image(systemName: "pencil.line") }
                    .buttonStyle(.borderless)
                    .help("Correct the categorization (Return)")
            }
            .opacity(showsHoverActions ? 1 : 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}
