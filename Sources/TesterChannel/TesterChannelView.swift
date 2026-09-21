import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// The conversation, as a drop-in view.
///
/// Give it a height — it fills what it is given, like any other SwiftUI view,
/// and a thread is unbounded so it will happily fill more than you meant.
///
/// ```swift
/// TesterChannelView(client: tc)
///     .frame(height: 520)
/// ```
///
/// D16: nothing here identifies Tester Channel. The panel wears the host's name
/// and colours, and a tester should experience it as part of the app they were
/// already using.
@MainActor
public struct TesterChannelView: View {
    @ObservedObject private var client: TesterChannelClient
    @State private var draft = ""
    @State private var nameDraft = ""
    @State private var savingName = false
    @State private var nameFailed = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var streamWidth: CGFloat = 320
    /// Whether the reader is at the bottom of the thread, as of the last layout —
    /// so it still says where they were when something new arrives.
    @State private var atBottom = true
    @State private var metrics = ScrollMetrics()
    /// Set by Send, spent by the next change at the bottom of the thread.
    @State private var followOwn = false
    @State private var hasFollowed = false
    /// The message the reader was on when they asked for the page above it,
    /// held until that page has been laid out and can be scrolled past.
    @State private var holdAnchor: String?
    @FocusState private var composerFocused: Bool

    public init(client: TesterChannelClient) {
        self.client = client
    }

    private var look: ResolvedAppearance {
        ResolvedAppearance(client.app?.appearance, appName: client.app?.name ?? "")
    }
    private var words: PanelStrings { client.words }

    public var body: some View {
        let look = self.look
        VStack(spacing: 0) {
            header(look)
            if client.tester?.needsName == true { naming(look) }
            stream(look)
            if client.isRemoved {
                removedNotice(look)
            } else {
                if !client.staged.isEmpty || client.uploadError != nil { stagedStrip(look) }
                composer(look)
            }
        }
        .background(look.surface)
        .foregroundStyle(ResolvedAppearance.ink)
        .clipShape(RoundedRectangle(cornerRadius: look.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: look.cornerRadius, style: .continuous)
                .strokeBorder(Color.black.opacity(0.10), lineWidth: 1)
        )
        .onAppear {
            client.setVisible(true)
            nameDraft = client.tester?.suggestedName ?? ""
        }
        // The profile usually arrives *after* this view appears — the guide
        // says to await identify before showing the panel, and the integration
        // examples mount it and identify in a `.task` under it, which is the
        // order most hosts end up with. Read once in `onAppear` the suggestion
        // was therefore read before there was one, and `traits.name` — the
        // whole point of which is that somebody happy with it agrees in one
        // click — never reached the box.
        //
        // Only into an empty box: a suggestion is a starting point, not
        // something to overwrite what somebody is halfway through typing.
        .onChange(of: client.tester?.suggestedName) { suggestion in
            if nameDraft.isEmpty, let suggestion { nameDraft = suggestion }
        }
        .onDisappear { client.setVisible(false) }
        .task { await client.refresh() }
        .onChange(of: picked) { items in Task { await ingest(items) } }
    }

    // MARK: Header

    @ViewBuilder
    private func header(_ look: ResolvedAppearance) -> some View {
        HStack(spacing: 10) {
            avatar(look)
            VStack(alignment: .leading, spacing: 1) {
                Text(look.teamName)
                    .font(font(look, 14, .semibold))
                Text(words.subtitle)
                    .font(font(look, 11.5))
                    .opacity(0.6)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            // Transparent rather than absent while the naming strip is up, so
            // the header keeps its height and the thread does not jump by a
            // pixel when somebody saves their name.
            Rectangle()
                .fill(Color.black.opacity(client.tester?.needsName == true ? 0 : 0.08))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func avatar(_ look: ResolvedAppearance) -> some View {
        Group {
            if let url = look.teamAvatarUrl {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    monogram(look)
                }
            } else {
                monogram(look)
            }
        }
        .frame(width: 28, height: 28)
        .background(look.accent)
        .clipShape(Circle())
    }

    private func monogram(_ look: ResolvedAppearance) -> some View {
        Text(look.monogram)
            .font(font(look, 13, .semibold))
            .foregroundStyle(.white)
    }

    // MARK: Naming strip

    /// Asked until *they* answer, and gone for good once they have.
    ///
    /// The product's own cheerful lime rather than a tint of the accent: this is
    /// the one thing in the panel meant to be noticed, and a wash of a dark
    /// accent reads as neither cheerful nor an aside. A host whose product it
    /// fights with overrides `notice`.
    @ViewBuilder
    private func naming(_ look: ResolvedAppearance) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(words.namePrompt)
                .font(font(look, 13, .semibold))
            HStack(spacing: 8) {
                TextField(words.namePlaceholder, text: $nameDraft)
                    .textFieldStyle(.plain)
                    .font(font(look, 13))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(look.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.28), lineWidth: 1)
                    )
                    .submitLabel(.done)
                    .onSubmit { Task { await saveName() } }
                Button { Task { await saveName() } } label: {
                    Text(words.nameSave)
                        .font(font(look, 13, .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(look.accent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .disabled(savingName || nameDraft.trimmed.isEmpty)
                .opacity(savingName || nameDraft.trimmed.isEmpty ? 0.45 : 1)
            }
            if nameFailed {
                Text(words.nameFailed)
                    .font(font(look, 12, .semibold))
                    .foregroundStyle(Color(red: 0x7a / 255, green: 0x21 / 255, blue: 0x09 / 255))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(look.notice)
        .foregroundStyle(ResolvedAppearance.ink)
    }

    private func saveName() async {
        let name = nameDraft.trimmed
        guard !name.isEmpty, !savingName else { return }
        savingName = true
        nameFailed = false
        defer { savingName = false }
        do { try await client.setDisplayName(name) } catch { nameFailed = true }
    }

    // MARK: Stream

    @ViewBuilder
    private func stream(_ look: ResolvedAppearance) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if client.hasOlder { olderButton(look, proxy) }
                    if client.messages.isEmpty && client.pending.isEmpty {
                        Text(words.empty)
                            .font(font(look, 13))
                            .opacity(0.55)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                    ForEach(client.messages) { message in
                        row(message, look)
                            .id(message.id)
                    }
                    ForEach(client.pending) { item in
                        // A queued item, shown where it will land so sending
                        // never looks like nothing happened. Pushed to the right
                        // the way a sent row is: `bubble` only caps its width, so
                        // without this a queued message sat on the team's side.
                        bubble(text: item.text, look: look, alignment: .trailing,
                               background: look.accent, foreground: .white,
                               timestamp: nil, queued: true,
                               footnote: item.isSending ? nil : words.offline)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .id(item.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: WidthKey.self, value: geo.size.width)
                            .preference(key: ContentFrameKey.self,
                                        value: geo.frame(in: .named(Self.streamSpace)))
                    }
                )
            }
            .coordinateSpace(name: Self.streamSpace)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ViewportHeightKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(WidthKey.self) { streamWidth = max($0, 120) }
            .onPreferenceChange(ViewportHeightKey.self) {
                metrics.viewportHeight = $0
                measure()
            }
            .onPreferenceChange(ContentFrameKey.self) {
                metrics.content = $0
                measure()
            }
            .onChange(of: StreamTail(client)) { _ in follow(proxy) }
            .onChange(of: client.messages.count) { _ in
                // After the view has taken the new messages, which is what the
                // held anchor is waiting for.
                if let anchor = holdAnchor { restore(anchor, proxy) }
                Task { await client.markRead() }
            }
            .onAppear {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                Task { await client.markRead() }
            }
        }
    }

    private static let bottomAnchor = "tc-bottom"
    private static let streamSpace = "tc-stream"

    /// Something changed at the bottom of the thread: a message arrived, or one
    /// was queued. The web client's rule, for the same reasons: follow your own
    /// message down wherever you were, and follow anything else only if you were
    /// already at the bottom — yanking somebody back down while they read history
    /// is its own small betrayal. Answering a card is deliberately not a send:
    /// the card can be a long way up, and the tester is looking at it.
    ///
    /// Keyed on the tail rather than the count, so Load older messages — which
    /// changes the count and not the tail — never lands here.
    private func follow(_ proxy: ScrollViewProxy) {
        let own = followOwn
        followOwn = false
        let wasAtBottom = metrics.atBottomBeforeChange ?? atBottom
        metrics.atBottomBeforeChange = nil
        // The first fill is the thread opening, not something arriving: it goes
        // to the bottom whatever was measured before there was anything in it,
        // and it should already be there rather than be seen travelling there.
        guard own || wasAtBottom || !hasFollowed else { return }
        if hasFollowed {
            withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        } else {
            hasFollowed = true
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    /// Whether the bottom of the thread is within reach of the bottom of the view.
    ///
    /// When the content changes height, the answer from just before is kept as
    /// well, because that is the question `follow` asks — where the reader *was*
    /// — and by the time it asks, the new content has already been laid out and
    /// measured. On iOS 27 that happens before the tail's `onChange` runs, so the
    /// fresh answer took every arrival for one the reader had scrolled away from.
    /// A scroll clears it: after that, the fresh answer is where they are.
    ///
    /// Not simply "ignore height changes": a lazy stack re-estimates its height
    /// on its own, typically as a scroll animation settles, and ignoring those
    /// left the answer stuck wherever the animation was mid-flight.
    ///
    /// Either measurement can arrive first, so both land here. Every frame of a
    /// scroll does too, which is why the measurements live in a reference that
    /// SwiftUI does not watch and only a change in the answer is written: a state
    /// write per frame would redraw the whole panel per frame.
    private func measure() {
        guard metrics.viewportHeight > 0, let content = metrics.content else { return }
        if content.height != metrics.contentHeight {
            metrics.contentHeight = content.height
            metrics.atBottomBeforeChange = atBottom
        } else {
            metrics.atBottomBeforeChange = nil
        }
        let now = content.maxY - metrics.viewportHeight < 40
        if now != atBottom { atBottom = now }
    }

    /// Load older messages, holding the place they were reading.
    ///
    /// Everything that arrives goes in above the viewport, and a scroll view
    /// keeps its offset from the top — so without this the message they were
    /// reading is pushed down by a page and they are looking at somebody else's.
    /// The message that was first sits just under this button, so it goes back
    /// to the top.
    private func loadOlder(_ proxy: ScrollViewProxy) async {
        guard let reading = client.messages.first?.id else { return }
        // Handed to the stream's own change handler rather than scrolled to
        // here. `DispatchQueue.main.async` from this method runs before the
        // lazy stack has laid the prepended page out, so the proxy resolved the
        // anchor against an estimate and landed a whole page above it — the
        // reader asked for the page above and was sent to the top of it, which
        // is the same rule broken in the other direction.
        let before = client.messages.count
        holdAnchor = reading
        await client.loadOlder()
        // Nothing arrived — the page was empty, or the request failed and the
        // button stays for another try. Either way no layout change is coming
        // to spend the anchor on, and an anchor left set would be spent by the
        // next unrelated arrival instead, pulling the reader back to a message
        // they may have scrolled a long way from.
        if client.messages.count == before { holdAnchor = nil }
    }

    /// Put the reader back on the message they were reading, once the page
    /// above it exists.
    ///
    /// Twice, and both passes earn their place. A `LazyVStack` has not measured
    /// a row it has never shown, so the first call is what forces the anchor to
    /// be built; the second, on the far side of that layout, is the one that
    /// lands on it. Without animation, because this is meant to look like the
    /// page was always there rather than like a journey.
    private func restore(_ anchor: String, _ proxy: ScrollViewProxy) {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { proxy.scrollTo(anchor, anchor: .top) }
        DispatchQueue.main.async {
            withTransaction(instant) { proxy.scrollTo(anchor, anchor: .top) }
            holdAnchor = nil
        }
    }

    /// The way back through a thread that may be years long. In the stream
    /// rather than pinned above it, because it belongs at the top of the
    /// conversation and should scroll away once there is nothing older.
    @ViewBuilder
    private func olderButton(_ look: ResolvedAppearance, _ proxy: ScrollViewProxy) -> some View {
        HStack {
            Spacer()
            Button { Task { await loadOlder(proxy) } } label: {
                Text(words.loadOlder)
                    .font(font(look, 12.5))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .overlay(
                        Capsule().strokeBorder(Color.black.opacity(0.15), lineWidth: 1)
                    )
            }
            .disabled(client.isLoadingOlder)
            .opacity(client.isLoadingOlder ? 0.4 : 0.75)
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.bottom, 4)
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ m: Message, _ look: ResolvedAppearance) -> some View {
        if m.kind.isCard {
            CardRow(
                message: m, look: look, words: words,
                maxWidth: streamWidth * 0.88,
                // An explicit closure rather than passing `font` by name: that
                // method carries a default argument, and handing a defaulted
                // method around as a value is the kind of thing that resolves
                // to the wrong arity on a bad day.
                fontFor: { self.font($0, $1, $2) },
                respond: { body, echo in
                    await client.respond(messageId: m.id, body: body, echo: echo)
                },
                // After a failed test the cursor goes to the composer. There is
                // no note field on the card by design, so "what broke" lands in
                // the thread where both sides can read it back.
                focusComposer: { composerFocused = true }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if m.isSystem {
            // Neither side's remark. Centred, and outlined rather than filled.
            VStack(alignment: .center, spacing: 3) {
                Text(m.bodyText).font(font(look, 13))
                timestamp(m.createdAt, look)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: streamWidth * 0.92)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .opacity(0.75)
            .frame(maxWidth: .infinity, alignment: .center)
        } else {
            // `inbound` is the tester, and it goes on the right — the opposite
            // of where the console puts it. Both surfaces are read by somebody
            // who expects their own words on the right, so making the two agree
            // would put one of them backwards.
            let mine = m.isFromTester
            bubble(
                text: m.bodyText, look: look,
                alignment: mine ? .trailing : .leading,
                background: mine ? look.accent : Color.black.opacity(0.05),
                foreground: mine ? .white : ResolvedAppearance.ink,
                timestamp: m.createdAt, queued: false,
                footnote: m.kind.isKnown ? nil : words.unsupportedCard,
                attachments: m.attachments ?? []
            )
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        }
    }

    @ViewBuilder
    private func bubble(
        text: String, look: ResolvedAppearance, alignment: HorizontalAlignment,
        background: Color, foreground: Color, timestamp when: Date?, queued: Bool,
        footnote: String? = nil, attachments: [Attachment] = []
    ) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            if !text.isEmpty {
                Text(text)
                    .font(font(look, 14))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
            }
            ForEach(attachments) { a in
                shot(a, look: look)
                    .padding(.top, 6)
            }
            if let footnote {
                Text(footnote)
                    .font(font(look, 12))
                    .opacity(0.6)
                    .padding(.top, 6)
            }
            if let when { timestamp(when, look).padding(.top, 3) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(background)
        .foregroundStyle(foreground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: streamWidth * 0.78, alignment: alignment == .trailing ? .trailing : .leading)
        .opacity(queued ? 0.55 : 1)
    }

    /// A screenshot, holding its own shape while it loads.
    ///
    /// The picture's width and height come down with it, so the space is
    /// reserved and the thread does not jump about as images arrive. The signed
    /// URL expires after thirty minutes, which is why nothing here caches it —
    /// the next poll re-reads the window and mints a fresh one.
    @ViewBuilder
    private func shot(_ a: Attachment, look: ResolvedAppearance) -> some View {
        AsyncImage(url: URL(string: absolute(a.url))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
            default:
                Rectangle().fill(Color.black.opacity(0.05))
            }
        }
        .aspectRatio(a.aspectRatio.map { CGFloat($0) }, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityLabel(a.filename ?? words.attachedImage)
    }

    /// Attachment URLs come back rooted at the service, not absolute.
    private func absolute(_ path: String) -> String {
        path.hasPrefix("http") ? path : client.baseUrl + path
    }

    private func timestamp(_ when: Date, _ look: ResolvedAppearance) -> some View {
        Text(when.formatted(date: .abbreviated, time: .shortened))
            .font(font(look, 10.5))
            .opacity(0.6)
    }

    // MARK: Composer

    @ViewBuilder
    private func stagedStrip(_ look: ResolvedAppearance) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = client.uploadError {
                Text(error)
                    .font(font(look, 12, .semibold))
                    .foregroundStyle(Color(red: 0x6d / 255, green: 0x4a / 255, blue: 0x12 / 255))
            }
            if !client.staged.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(client.staged) { s in chip(s, look) }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func chip(_ s: StagedAttachment, _ look: ResolvedAppearance) -> some View {
        HStack(spacing: 6) {
            if let data = s.preview, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable().scaledToFill()
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            Text(s.filename.isEmpty ? words.unnamedImage : s.filename)
                .font(font(look, 12))
                .lineLimit(1)
            Button { client.unstage(s.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(0.55)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(PanelStrings.fill(words.remove, ["name": s.filename]))
        }
        .padding(4)
        .padding(.trailing, 6)
        .frame(maxWidth: 190)
        .background(Color.black.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func composer(_ look: ResolvedAppearance) -> some View {
        HStack(spacing: 8) {
            PhotosPicker(selection: $picked, maxSelectionCount: maxAttachmentsPerMessage,
                         matching: .images) {
                Image(systemName: "paperclip")
                    .font(.system(size: 17))
                    .frame(width: 38, height: 38)
                    .background(look.surface)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(client.staged.count >= maxAttachmentsPerMessage)
            .opacity(client.staged.count >= maxAttachmentsPerMessage ? 0.45 : 1)
            .accessibilityLabel(words.attach)

            TextField(words.composer, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(font(look, 14))
                .lineLimit(1...4)
                .focused($composerFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(minHeight: 38)
                .background(Color.white)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.15), lineWidth: 1))

            Button {
                let text = draft
                draft = ""
                followOwn = true
                Task { await client.send(text) }
            } label: {
                Text(words.send)
                    .font(font(look, 14, .semibold))
                    .padding(.horizontal, 16)
                    .frame(height: 38)
                    .background(look.accent)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmed.isEmpty && client.staged.isEmpty)
            .opacity(draft.trimmed.isEmpty && client.staged.isEmpty ? 0.45 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)
        }
    }

    /// Removal is not erasure: the conversation stays readable, and only the
    /// composer goes. A textarea you cannot type in reads as broken rather than
    /// as a rule.
    @ViewBuilder
    private func removedNotice(_ look: ResolvedAppearance) -> some View {
        Text(words.removedNotice)
            .font(font(look, 13))
            .opacity(0.65)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)
            }
    }

    private func ingest(_ items: [PhotosPickerItem]) async {
        defer { picked = [] }
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let name = item.supportedContentTypes.first?.preferredFilenameExtension
                .map { "screenshot.\($0)" } ?? "screenshot.jpg"
            let mime = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
            let ok = await client.attach(data: data, filename: name, mimeType: mime)
            if !ok { break }
        }
    }

    // MARK: Type

    fileprivate func font(
        _ look: ResolvedAppearance, _ size: CGFloat, _ weight: Font.Weight = .regular
    ) -> Font {
        if let name = look.fontName {
            return .custom(name, size: size).weight(weight)
        }
        return .system(size: size, weight: weight)
    }
}

/// `let`, not `var`: a stored static `var` is shared mutable state, which
/// Swift 6 refuses, and nothing ever wrote to it.
private struct WidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 320
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Where the thread's content is, in the scroll view's own coordinates.
///
/// Neither this nor the viewport key takes the next value outright: SwiftUI also
/// folds in the default from every sibling that sets nothing, so `reduce` has to
/// leave a value unchanged when handed the default. Taking the next value let
/// the default win, and neither key ever reported a measurement.
private struct ContentFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

private struct ViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// What `measure()` compares. A class, so writing it on every frame of a scroll
/// does not invalidate the view.
private final class ScrollMetrics {
    var content: CGRect?
    var viewportHeight: CGFloat = 0
    /// The content height the last answer was worked out against.
    var contentHeight: CGFloat = -1
    /// `atBottom` from before the content last changed height, until the reader
    /// next scrolls.
    var atBottomBeforeChange: Bool?
}

/// What changes at the bottom of the thread, and only that. The count is not in
/// it on purpose: Load older messages changes the count and nothing down here.
private struct StreamTail: Equatable {
    let lastMessage: String?
    let pending: [UUID]

    @MainActor
    init(_ client: TesterChannelClient) {
        lastMessage = client.messages.last?.id
        pending = client.pending.map(\.id)
    }
}
