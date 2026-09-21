import Foundation
import SwiftUI

/// How many images one message carries.
///
/// The service refuses a fifth rather than dropping it, so this is not the only
/// thing standing between a tester and a lost screenshot — but capping here is
/// what lets somebody be told while they can still un-stage one, instead of
/// after the send fails. Mirrors `MAX_PER_MESSAGE` in `src/images.ts`, which is
/// the authority.
public let maxAttachmentsPerMessage = 4

/// How much of the conversation arrives at once.
public let defaultPageSize = 30

/// An outbound item waiting to reach the service.
///
/// Offline is the normal case, not the exception: testers file their best
/// feedback in exactly the conditions that break a network, so an outbound
/// message is queued with a visible pending state and retried rather than lost.
public struct PendingItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case message(text: String, attachmentIds: [String])
        /// `echo` is what the tester will see in the thread once it lands, shown
        /// immediately so answering a card does not look like nothing happened.
        case answer(messageId: String, body: AnswerBody, echo: String)
    }
    public let id = UUID()
    public var kind: Kind
    /// Reused across every retry. This is what makes a retry safe: the service
    /// keeps the first copy and answers 200 `duplicate` to the rest.
    public let clientNonce = UUID().uuidString
    public var isSending = false
    public var text: String {
        switch kind {
        case .message(let t, _): return t
        case .answer(_, _, let echo): return echo
        }
    }
}

public struct AnswerBody: Codable, Equatable, Sendable {
    public let kind: String
    public let selected: [Int]?
    public let outcome: String?

    public static func poll(_ selected: [Int]) -> AnswerBody {
        AnswerBody(kind: "poll", selected: selected, outcome: nil)
    }
    public static func testOutcome(passed: Bool) -> AnswerBody {
        AnswerBody(kind: "test_request", selected: nil, outcome: passed ? "passed" : "failed")
    }
}

/// A screenshot the tester has picked but not yet sent.
public struct StagedAttachment: Identifiable, Equatable, Sendable {
    public let id: String
    public let filename: String
    public let url: String
    public var preview: Data?
}

/// The client. One per signed-in person; hand it to `TesterChannelView`.
///
/// ```swift
/// let tc = TesterChannelClient(publishableKey: "pk_live_…", baseUrl: "https://…")
/// try await tc.identify(userId: user.id, userHash: hashFromYourBackend)
/// // then, in your view hierarchy:
/// TesterChannelView(client: tc)
/// ```
///
/// `userHash` is an HMAC your own backend computes. The HMAC secret must never
/// reach this process — anyone holding it can impersonate any tester of the app.
@MainActor
public final class TesterChannelClient: ObservableObject {

    // MARK: Published state

    @Published public private(set) var messages: [Message] = []
    @Published public private(set) var pending: [PendingItem] = []
    @Published public private(set) var staged: [StagedAttachment] = []
    @Published public private(set) var app: AppInfo?
    @Published public private(set) var tester: TesterProfile?
    @Published public private(set) var hasOlder = false
    @Published public private(set) var isLoadingOlder = false
    @Published public private(set) var uploadError: String?
    /// Set when the service says this tester has been removed (D17). The panel
    /// stops offering to write; the conversation stays readable.
    @Published public private(set) var isRemoved = false
    @Published public private(set) var words = PanelStrings()

    /// The service's own number, not a guess.
    ///
    /// The web client used to derive this from a set built up in memory, which
    /// started empty — so every launch counted the tester's whole history as
    /// unread and the badge opened on some enormous number and then fell. The
    /// count comes off the thread response and off `GET /client/unread`.
    @Published public private(set) var unreadCount = 0

    public var isEnabled: Bool { session != nil }
    public var displayName: String? { tester?.displayName }

    // MARK: Configuration

    public let publishableKey: String
    public let baseUrl: String
    public var pollInterval: Duration = .seconds(4)
    /// What the poll costs while the panel is not on screen. A badge does not
    /// need four-second freshness, and hidden the client fetches one integer
    /// rather than the conversation.
    public var idlePollInterval: Duration = .seconds(30)
    public var pageSize: Int = defaultPageSize
    /// Applied on top of the console's translations, so a host can override any
    /// single word without taking on the rest.
    public var stringOverrides: [String: String] = [:] { didSet { refreshWords() } }

    // MARK: Private state

    private var session: String?
    private var locale: String?
    /// Which outbound ids a receipt has already covered.
    ///
    /// Without this the client posted every outbound id in the thread on every
    /// render, twice per poll, for as long as the panel stayed open — a write,
    /// and a request body that grew without bound, for ever.
    private var acked: Set<String> = []
    private var pollTask: Task<Void, Never>?
    private var isVisible = false
    private let urlSession: URLSession

    public init(publishableKey: String, baseUrl: String, urlSession: URLSession = .shared) {
        self.publishableKey = publishableKey
        self.baseUrl = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        self.urlSession = urlSession
    }

    // MARK: - Session

    /// The handshake. Call it once per signed-in person, and await it before
    /// putting the panel on screen.
    @discardableResult
    public func identify(
        userId: String,
        userHash: String,
        traits: [String: String]? = nil,
        build: String? = nil,
        locale: String? = nil
    ) async throws -> AppInfo {
        let wanted = locale ?? Locale.preferredLanguages.first
        self.locale = wanted

        var body: [String: Any] = [
            "userId": userId,
            "userHash": userHash,
            "platform": "ios",
        ]
        if let traits { body["traits"] = traits }
        if let wanted { body["locale"] = wanted }
        body["osVersion"] = Self.osVersion
        // The caller's own build string wins; the bundle's is a sensible default
        // so the operator's sidebar says something rather than nothing.
        let shipped = build
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        if let shipped { body["build"] = shipped }

        let res: IdentifyResponse = try await call(
            "/client/identify", method: "POST", json: body, authenticated: false)

        session = res.session
        app = res.app
        tester = res.tester
        isRemoved = false
        refreshWords()
        // Deliberately not a full refresh: the guide tells hosts to identify
        // before they show the panel, so at this point there is usually nothing
        // on screen and no reason to pull a conversation nobody is looking at.
        await tick()
        startPolling()
        return res.app
    }

    /// Sign-out. Drops the session and everything drawn from it.
    ///
    /// Not the same as hiding the panel — see `setVisible(_:)`. Closing a panel
    /// and signing somebody out were one act in an early version of the web
    /// client, which meant a badge could not outlive the thread it counts.
    public func reset() {
        stopPolling()
        session = nil
        messages = []
        pending = []
        staged = []
        tester = nil
        app = nil
        acked = []
        unreadCount = 0
        hasOlder = false
        isRemoved = false
        uploadError = nil
        // The app has gone, so its translations go with it — back to the packs
        // this client ships under whatever the host passed in code. Left out,
        // the panel kept the previous app's words after a sign-out, which the
        // web client does not do.
        refreshWords()
    }

    /// Whether the conversation is on screen. `TesterChannelView` drives this;
    /// call it yourself only if you are drawing your own UI.
    ///
    /// Visible, the client polls the conversation on `pollInterval`. Hidden, it
    /// polls one integer on `idlePollInterval` — which is the case a badge is
    /// for, and the case that has to stay cheap as a thread grows for years.
    public func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        guard isEnabled else { return }
        startPolling()
        Task { await tick() }
    }

    // MARK: - Reading

    /// Re-read the window currently on screen.
    ///
    /// `from` rather than a count: asking for "the newest thirty" on every tick
    /// drops a message off the top of the list each time one arrives at the
    /// bottom. And re-reading rather than only asking for what is new, because
    /// what is already on screen can change — a card answered on another device
    /// has to collapse here too, and the signed URL on every attachment expires.
    public func refresh() async {
        guard isEnabled else { return }
        do {
            var query = "limit=\(pageSize)"
            if let anchor = messages.first?.id { query = "from=\(anchor)" }
            let res: ThreadResponse = try await call("/client/thread?\(query)")
            take(res)
            await flush()
        } catch let e as TesterChannelError where e.isUnauthorized {
            session = nil
            stopPolling()
        } catch {
            // A failed poll is not an event. The next one will try again.
        }
    }

    /// One page further back. No-op while already loading, or at the top.
    public func loadOlder() async {
        guard isEnabled, hasOlder, !isLoadingOlder, let oldest = messages.first?.id else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let res: ThreadResponse = try await call(
                "/client/thread?before=\(oldest)&limit=\(pageSize)")
            let known = Set(messages.map(\.id))
            messages.insert(contentsOf: res.messages.filter { !known.contains($0.id) }, at: 0)
            hasOlder = res.hasOlder
        } catch {
            // Leave the button where it is; the tester can try again.
        }
    }

    private func take(_ res: ThreadResponse) {
        messages = res.messages
        hasOlder = res.hasOlder
        if let t = res.tester { tester = t }
        if let meta = res.thread { unreadCount = meta.unreadForTester }
    }

    private func pollUnread() async {
        guard isEnabled else { return }
        do {
            let res: UnreadResponse = try await call("/client/unread")
            if res.unread != unreadCount { unreadCount = res.unread }
        } catch let e as TesterChannelError where e.isUnauthorized {
            session = nil
            stopPolling()
        } catch {}
    }

    private func tick() async {
        if isVisible { await refresh() } else { await pollUnread() }
    }

    private func startPolling() {
        stopPolling()
        let interval = isVisible ? pollInterval : idlePollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                // Retires itself once the client is gone, which is why there is
                // no deinit: touching isolated state from one is a concurrency
                // error, and a cancel that cannot run is not worth the trouble.
                guard !Task.isCancelled, let self else { return }
                await self.tick()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Writing

    /// Queue a message. Returns immediately; the send happens in the outbox.
    public func send(_ text: String) async {
        let trimmed = text.trimmed
        let ids = staged.map(\.id)
        guard !trimmed.isEmpty || !ids.isEmpty else { return }
        staged = []
        pending.append(PendingItem(kind: .message(text: text, attachmentIds: ids)))
        await flush()
    }

    /// Answer a card. Ignored if this card already has an answer in the queue.
    public func respond(messageId: String, body: AnswerBody, echo: String) async {
        let alreadyQueued = pending.contains {
            if case .answer(let id, _, _) = $0.kind { return id == messageId }
            return false
        }
        guard !alreadyQueued else { return }
        pending.append(PendingItem(kind: .answer(messageId: messageId, body: body, echo: echo)))
        await flush()
    }

    private func flush() async {
        for item in pending where !item.isSending {
            guard let idx = pending.firstIndex(where: { $0.id == item.id }) else { continue }
            pending[idx].isSending = true
            do {
                switch item.kind {
                case .message(let text, let attachmentIds):
                    let body: [String: Any] = [
                        "text": text,
                        "clientNonce": item.clientNonce,
                        "attachmentIds": attachmentIds,
                    ]
                    let _: DiscardedBody = try await call(
                        "/client/messages", method: "POST", json: body)
                case .answer(let messageId, let answer, _):
                    let _: DiscardedBody = try await call(
                        "/client/messages/\(messageId)/respond",
                        method: "POST", json: answer.asDictionary)
                }
                pending.removeAll { $0.id == item.id }
                await reload()
            } catch let e as TesterChannelError where e.isAlreadyAnswered {
                // Success. A queued retry raced the first attempt and the answer
                // is recorded — by status, not by matching the English of the
                // message, because the wording is not the contract.
                pending.removeAll { $0.id == item.id }
                await reload()
            } catch let e as TesterChannelError where e.isRemoved {
                isRemoved = true
                pending.removeAll { $0.id == item.id }
            } catch {
                // Stays queued. The next poll tries again.
                if let i = pending.firstIndex(where: { $0.id == item.id }) {
                    pending[i].isSending = false
                }
            }
        }
    }

    private func reload() async {
        guard isEnabled else { return }
        var query = "limit=\(pageSize)"
        if let anchor = messages.first?.id { query = "from=\(anchor)" }
        if let res: ThreadResponse = try? await call("/client/thread?\(query)") { take(res) }
    }

    /// Upload one image and stage it against the next message.
    ///
    /// Not queued the way a message is: the file is the payload, and holding
    /// megabytes in memory hoping the network returns is a worse failure than
    /// saying the upload did not work.
    @discardableResult
    public func attach(data: Data, filename: String, mimeType: String = "image/jpeg") async -> Bool {
        uploadError = nil
        guard staged.count < maxAttachmentsPerMessage else {
            uploadError = PanelStrings.fill(
                words.tooMany, ["max": String(maxAttachmentsPerMessage)])
            return false
        }
        do {
            let res: AttachmentResponse = try await upload(
                data: data, filename: filename, mimeType: mimeType)
            staged.append(StagedAttachment(
                id: res.attachment.id, filename: res.attachment.filename ?? filename,
                url: res.attachment.url, preview: data))
            return true
        } catch let e as TesterChannelError where e.isRemoved {
            isRemoved = true
            return false
        } catch let e as TesterChannelError {
            uploadError = e.message
            return false
        } catch {
            uploadError = words.uploadFailed
            return false
        }
    }

    public func unstage(_ id: String) {
        staged.removeAll { $0.id == id }
    }

    /// What the tester wants to be called. Theirs — nothing on the operator side
    /// writes it, and identify does not touch it, so the host app cannot
    /// overwrite it on the next handshake.
    public func setDisplayName(_ name: String) async throws {
        let res: ProfileResponse = try await call(
            "/client/profile", method: "PATCH", json: ["displayName": name])
        tester = res.tester
    }

    /// Tell the service what has been read.
    ///
    /// Only ids no receipt has covered yet, so this is cheap when there is
    /// nothing to say — which is most of the time.
    public func markRead() async {
        guard isEnabled else { return }
        let unseen = messages
            .filter { !$0.isFromTester && !acked.contains($0.id) }
            .map(\.id)
        guard !unseen.isEmpty else { return }
        unseen.forEach { acked.insert($0) }
        unreadCount = 0
        do {
            let _: DiscardedBody = try await call(
                "/client/receipts", method: "POST", json: ["messageIds": unseen])
        } catch {
            // Put them back so the next render tries again.
            unseen.forEach { acked.remove($0) }
        }
    }

    // MARK: - Words

    /// Mirrors `#refreshWords` in the web client, layer for layer.
    ///
    /// The English defaults underneath, because they are the only layer that is
    /// always complete. Then the language pack we ship, if we ship one. Then the
    /// app's own translations, which an operator edits in the console. Then
    /// whatever the host passed in code, which wins because it is the layer
    /// nearest the app: somebody who wrote a word into their own source meant
    /// that word, and a console edit reaching across to undo it would be a
    /// change nobody could find the cause of.
    ///
    /// The bundled layer is also why `BundledStrings.locales` joins the tags
    /// below rather than only the app's. Without it a German tester of an app
    /// nobody has translated matched nothing and read English, while the same
    /// tester on the web read German — the packs would have been present and
    /// unreachable, which is the same as not shipping them.
    private func refreshWords() {
        var tags = BundledStrings.locales
        if let theirs = app?.strings { tags.append(contentsOf: theirs.keys) }
        let tag = LocaleMatch.best(available: tags, wanted: locale)
            ?? LocaleMatch.best(available: tags, wanted: app?.defaultLocale)

        var next = PanelStrings()
        next.apply(Self.bucket(BundledStrings.packs, tag))
        next.apply(Self.bucket(app?.strings, tag))
        next.apply(stringOverrides)
        words = next
    }

    /// One language out of a map, matched again within that map.
    ///
    /// Re-matched rather than looked up by the tag chosen above, because the two
    /// maps need not spell it the same way: we ship `cs` and an operator may have
    /// written `cs-CZ`, and a plain subscript would silently drop whichever of
    /// the two did not match the winning spelling. The web client's `bucket`
    /// does exactly this and for exactly this reason.
    private static func bucket(_ map: [String: [String: String]]?, _ tag: String?) -> [String: String] {
        guard let map, !map.isEmpty, let tag,
              let hit = LocaleMatch.best(available: Array(map.keys), wanted: tag) else { return [:] }
        return map[hit] ?? [:]
    }

    /// Change language without a new handshake. `app.strings` carries every
    /// language at once precisely so this costs nothing.
    public func setLocale(_ locale: String?) {
        self.locale = locale
        refreshWords()
    }

    // MARK: - Transport

    private static var osVersion: String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
        #endif
    }

    private func request(_ path: String, method: String, authenticated: Bool) throws -> URLRequest {
        guard let url = URL(string: "\(baseUrl)/v1\(path)") else {
            throw TesterChannelError(status: 0, code: nil, message: "Bad base URL.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if authenticated {
            guard let session else {
                throw TesterChannelError(status: 401, code: "unauthorized", message: "Identify first.")
            }
            req.setValue(session, forHTTPHeaderField: "X-Tester-Session")
        } else {
            req.setValue(publishableKey, forHTTPHeaderField: "X-Publishable-Key")
        }
        return req
    }

    @discardableResult
    private func call<T: Decodable>(
        _ path: String, method: String = "GET",
        json: [String: Any]? = nil, authenticated: Bool = true
    ) async throws -> T {
        var req = try request(path, method: method, authenticated: authenticated)
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return try await perform(req)
    }

    private func upload<T: Decodable>(
        data: Data, filename: String, mimeType: String
    ) async throws -> T {
        var req = try request("/client/attachments", method: "POST", authenticated: true)
        let boundary = "tc-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        req.httpBody = body
        return try await perform(req)
    }

    private func perform<T: Decodable>(_ req: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch {
            throw TesterChannelTransportError(underlying: error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(status) else {
            // The status and the machine-readable code, not just the sentence.
            // Without them the only way to tell a conflict from a failure was to
            // match the English of the error message, which holds until somebody
            // rewords it.
            let body = try? JSONDecoder().decode(ServiceError.self, from: data)
            throw TesterChannelError(
                status: status, code: body?.code,
                message: body?.message ?? "Request failed (\(status))")
        }
        if T.self == DiscardedBody.self { return DiscardedBody() as! T }
        if data.isEmpty { return DiscardedBody() as! T }

        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw TesterChannelTransportError(underlying: error)
        }
    }

    /// `created_at` is an ISO-8601 timestamp with fractional seconds, which
    /// `.iso8601` alone does not accept.
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: raw) ?? plain.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Bad timestamp: \(raw)"))
        }
        return d
    }()

    private struct ServiceError: Decodable {
        let code: String?
        let message: String?
    }
}

/// A response body nobody reads — a 204, or a 201 whose contents the next
/// thread read supersedes anyway.
struct DiscardedBody: Decodable {
    init() {}
    init(from decoder: Decoder) throws {}
}

extension AnswerBody {
    var asDictionary: [String: Any] {
        var out: [String: Any] = ["kind": kind]
        if let selected { out["selected"] = selected }
        if let outcome { out["outcome"] = outcome }
        return out
    }
}
