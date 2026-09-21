import SwiftUI

/// A card — a poll or a test request — answered where it sits.
///
/// Never a sheet and never a separate screen: a card is a place to act inside
/// the conversation, and moving it somewhere else would break the one thing that
/// makes scrolling back readable.
///
/// It belongs to the company's side here, unlike in the console, where a card
/// runs the full width because it belongs to neither party. The same argument
/// was put to this surface and declined: an operator is reading somebody else's
/// conversation back, and the tester is not — the tester was asked, and the
/// asking came from the company.
@MainActor
struct CardRow: View {
    let message: Message
    let look: ResolvedAppearance
    let words: PanelStrings
    let maxWidth: CGFloat
    let fontFor: (ResolvedAppearance, CGFloat, Font.Weight) -> Font
    let respond: (AnswerBody, String) async -> Void
    /// Where the cursor goes after a failed test. There is no note field on the
    /// card by design — "what happened" belongs in the thread, where both sides
    /// can read it back, not in a field only the report shows.
    var focusComposer: () -> Void = {}

    @State private var selected: Set<Int> = []
    /// Which button is in flight, so only that one says so — and so a send
    /// that fails re-enables rather than leaving the card dead for good.
    @State private var submittingLabel: String?

    private var answered: Bool { message.answered == true }
    private var options: [String] { message.payload?.options ?? [] }
    private var isPoll: Bool { message.kind == .poll }

    private func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        fontFor(look, size, weight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text((isPoll ? words.poll : words.testRequest).uppercased())
                .font(font(10, .semibold))
                .tracking(1)
                .foregroundStyle(answered ? Color.black.opacity(0.45) : look.accent)
                .padding(.bottom, 5)

            if isPoll { pollBody } else { testBody }

            Text(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(font(10.5))
                .opacity(0.6)
                .padding(.top, 3)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .background(look.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(answered ? Color.black.opacity(0.12) : look.accent, lineWidth: 1)
        )
        // The spine, on the side the language reads from.
        .overlay(alignment: .leading) {
            look.accent.frame(width: 2)
                .clipShape(RoundedRectangle(cornerRadius: 1))
        }
    }

    // MARK: Poll

    @ViewBuilder
    private var pollBody: some View {
        Text(message.payload?.question ?? "")
            .font(font(14, .semibold))
            .padding(.bottom, 7)

        if answered {
            // The choice stays, the form does not. Scrolling back reads as
            // history rather than as a pile of stale prompts.
            let chosen = Set(message.answer?.selected ?? [])
            ForEach(Array(options.enumerated()), id: \.offset) { index, label in
                chosenRow(label, ticked: chosen.contains(index))
            }
        } else {
            ForEach(Array(options.enumerated()), id: \.offset) { index, label in
                Button {
                    toggle(index)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: symbol(for: index))
                            .font(.system(size: 16))
                            .foregroundStyle(selected.contains(index) ? look.accent : Color.black.opacity(0.4))
                        Text(label).font(font(14))
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected.contains(index) ? [.isSelected] : [])
            }

            actionButton(words.answer, ghost: false, enabled: !selected.isEmpty) {
                let picks = selected.sorted()
                let echo = picks.compactMap { options.indices.contains($0) ? options[$0] : nil }
                    .joined(separator: ", ")
                await respond(.poll(picks), echo)
            }
            .padding(.top, 9)
        }
    }

    private var multiSelect: Bool { message.payload?.multiSelect == true }

    private func symbol(for index: Int) -> String {
        let on = selected.contains(index)
        if multiSelect { return on ? "checkmark.square.fill" : "square" }
        return on ? "largecircle.fill.circle" : "circle"
    }

    private func toggle(_ index: Int) {
        if multiSelect {
            if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
        } else {
            selected = [index]
        }
    }

    // MARK: Test request

    @ViewBuilder
    private var testBody: some View {
        Text(message.payload?.title ?? "")
            .font(font(14, .semibold))
            .padding(.bottom, 7)

        let steps = message.payload?.steps ?? []
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1).").font(font(13.5))
                        Text(step).font(font(13.5))
                    }
                }
            }
            .opacity(0.8)
            .padding(.bottom, 9)
        }

        if answered {
            chosenRow(
                message.answer?.outcome == "passed" ? words.passed : words.failed,
                ticked: true)
        } else {
            HStack(spacing: 7) {
                actionButton(words.passed, ghost: false, enabled: true) {
                    await respond(.testOutcome(passed: true), words.passed)
                }
                actionButton(words.failed, ghost: true, enabled: true) {
                    await respond(.testOutcome(passed: false), words.failed)
                    focusComposer()
                }
            }
            .padding(.top, 9)
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private func chosenRow(_ label: String, ticked: Bool) -> some View {
        HStack(spacing: 7) {
            Text(ticked ? "✓" : "·")
                .font(font(13.5, .bold))
                .foregroundStyle(look.accent)
                .accessibilityHidden(true)
            Text(label).font(font(13.5))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .opacity(ticked ? 1 : 0.45)
        .accessibilityLabel(ticked
            ? PanelStrings.fill(words.optionChosen, ["option": label])
            : label)
    }

    @ViewBuilder
    private func actionButton(
        _ label: String, ghost: Bool, enabled: Bool, action: @escaping () async -> Void
    ) -> some View {
        Button {
            guard submittingLabel == nil else { return }
            submittingLabel = label
            Task {
                await action()
                submittingLabel = nil
            }
        } label: {
            Text(submittingLabel == label ? words.answering : label)
                .font(font(13.5, .semibold))
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .background(ghost ? Color.clear : look.accent)
                .foregroundStyle(ghost ? look.accent : .white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(look.accent, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled || submittingLabel != nil)
        .opacity(!enabled || submittingLabel != nil ? 0.5 : 1)
    }
}
