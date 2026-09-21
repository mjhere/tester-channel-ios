import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// A Tester Channel service that lives inside this app.
///
/// It answers the same `/v1/client/*` routes as `src/routes/client.ts`, with the
/// same JSON, from memory. That is enough to drive every state the panel has —
/// a long history, cards, a queue while offline, removal — on a simulator with
/// no server, no database and no network. It is not evidence about the real
/// service: when the two disagree, the service is right and this is stale.
///
/// Requests reach it through `FakeURLProtocol`, which only claims `host`, so
/// nothing else the app loads is touched.
final class FakeService: @unchecked Sendable {
    static let shared = FakeService()
    static let host = "demo.testerchannel.invalid"
    static let baseUrl = "https://\(host)"

    private let lock = NSLock()
    private var messages: [[String: Any]] = []
    private var answers: [String: [String: Any]] = [:]
    private var files: [String: Data] = [:]
    private var fileTypes: [String: String] = [:]
    private var nonces: Set<String> = []
    private var unread = 0
    private var displayName: String?
    private var nextId = 1

    /// Every request fails as if the network had gone, which is the normal case
    /// for a tester and the one a queued message exists for.
    var offline: Bool {
        get { lock.withLock { _offline } }
        set { lock.withLock { _offline = newValue } }
    }
    private var _offline = false

    /// The next write is refused with 403 `removed`, as D17 does.
    var removed: Bool {
        get { lock.withLock { _removed } }
        set { lock.withLock { _removed = newValue } }
    }
    private var _removed = false

    /// How long each answer takes. Long enough to see a pending state, short
    /// enough not to be in the way.
    let latency: TimeInterval = 0.35

    private init() { reset() }

    // MARK: - The operator's side

    /// Back to a thread with a history long enough that Load older has work to do.
    func reset() {
        lock.withLock {
            messages = []
            answers = [:]
            files = [:]
            fileTypes = [:]
            nonces = []
            unread = 0
            displayName = nil
            _offline = false
            _removed = false
            nextId = 1
            let start = Date().addingTimeInterval(-9 * 24 * 3600)
            for i in 1...80 {
                let at = start.addingTimeInterval(Double(i) * 2.5 * 3600)
                let fromTester = i % 3 == 0
                let text = fromTester
                    ? Self.testerLines[i % Self.testerLines.count]
                    : Self.teamLines[i % Self.teamLines.count]
                insert(direction: fromTester ? "inbound" : "outbound", origin: "direct",
                       type: "text", payload: ["text": "#\(i) · \(text)"], at: at)
            }
            // Arrived while they were away, so the badge has something to say.
            unread = 2
        }
    }

    /// Something the team writes, arriving at the bottom of the thread.
    func operatorSends(_ text: String? = nil) {
        lock.withLock {
            let n = messages.count + 1
            let line = text ?? Self.teamLines[n % Self.teamLines.count]
            insert(direction: "outbound", origin: "direct", type: "text",
                   payload: ["text": "#\(n) · \(line)"], at: Date())
            unread += 1
        }
    }

    func operatorSendsPoll(multiSelect: Bool) {
        lock.withLock {
            let payload: [String: Any] = multiSelect
                ? ["question": "Which of these did you use this week?",
                   "options": ["Checkout", "Search", "Wishlist", "Order history"],
                   "multiSelect": true]
                : ["question": "How did the new onboarding feel?",
                   "options": ["Quick and clear", "OK, a bit long", "Confusing"],
                   "multiSelect": false]
            insert(direction: "outbound", origin: "broadcast", type: "poll",
                   payload: payload, at: Date())
            unread += 1
        }
    }

    func operatorSendsTestRequest() {
        lock.withLock {
            insert(direction: "outbound", origin: "broadcast", type: "test_request",
                   payload: ["title": "Pay with Apple Pay in build 212",
                             "steps": ["Add any item to the basket",
                                       "Tap Checkout, then Apple Pay",
                                       "Confirm with the test card"]],
                   at: Date())
            unread += 1
        }
    }

    /// A card from a newer console, which this build has never heard of.
    func operatorSendsUnknownCard() {
        lock.withLock {
            insert(direction: "outbound", origin: "broadcast", type: "rating",
                   payload: ["question": "Rate today's build from 1 to 5"], at: Date())
            unread += 1
        }
    }

    func systemNotice() {
        lock.withLock {
            _ = insert(direction: "outbound", origin: "system", type: "system",
                   payload: ["text": "Build 1.4 (213) is available in TestFlight."], at: Date())
        }
    }

    /// Ask for their name again, as a new tester would be.
    func forgetName() {
        lock.withLock { displayName = nil }
    }

    // MARK: - Routing

    struct Reply {
        var status: Int
        var body: Data?
        var contentType = "application/json"
    }

    func handle(_ request: URLRequest, body: Data?) -> Reply {
        guard let url = request.url,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return error(400, "invalid", "Bad URL.")
        }
        let path = parts.path
        let query = Dictionary(
            (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { a, _ in a })
        let method = request.httpMethod ?? "GET"
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]

        if path.hasPrefix("/demo-files/") {
            let id = String(path.dropFirst("/demo-files/".count))
            return lock.withLock {
                files[id].map { Reply(status: 200, body: $0, contentType: fileTypes[id] ?? "image/jpeg") }
            } ?? error(404, "not_found", "No such file.")
        }

        if path != "/v1/client/identify" && request.value(forHTTPHeaderField: "X-Tester-Session") == nil {
            return error(401, "unauthorized", "Identify first.")
        }

        switch (method, path) {
        case ("POST", "/v1/client/identify"):
            return ok([
                "session": "demo-session",
                "app": [
                    "name": "1000 Fans Demo",
                    "appearance": NSNull(),
                    "strings": [String: Any](),
                    "default_locale": "en",
                ] as [String: Any],
                "tester": lock.withLock {
                    profile(suggested: (json?["traits"] as? [String: Any])?["name"] as? String)
                },
            ])
        case ("GET", "/v1/client/thread"):
            return thread(query)
        case ("GET", "/v1/client/unread"):
            return ok(["unread": lock.withLock { unread }])
        case ("POST", "/v1/client/messages"):
            return send(json ?? [:])
        case ("POST", _) where path.hasPrefix("/v1/client/messages/") && path.hasSuffix("/respond"):
            let id = path.dropFirst("/v1/client/messages/".count).dropLast("/respond".count)
            return respond(String(id), json ?? [:])
        case ("PATCH", "/v1/client/profile"):
            let name = (json?["displayName"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return error(400, "invalid", "displayName required.") }
            return ok(["tester": lock.withLock { () -> [String: Any] in
                displayName = name
                return profile(suggested: nil)
            }])
        case ("POST", "/v1/client/receipts"):
            lock.withLock { unread = 0 }
            return Reply(status: 204, body: nil)
        case ("POST", "/v1/client/attachments"):
            return attach(request, body: body ?? Data())
        default:
            return error(404, "not_found", "\(method) \(path) is not something this demo knows.")
        }
    }

    // MARK: - Routes

    /// The same three windows as the service: the newest `limit`, the page
    /// `before` a message, or everything `from` one onwards.
    private func thread(_ query: [String: String]) -> Reply {
        lock.withLock {
            let limit = Int(query["limit"] ?? "") ?? 30
            let window: ArraySlice<[String: Any]>
            if let from = query["from"] {
                guard let i = messages.firstIndex(where: { $0["id"] as? String == from }) else {
                    return error(400, "invalid", "from must name a message in this thread.")
                }
                window = messages[i...]
            } else {
                var end = messages.count
                if let before = query["before"] {
                    guard let i = messages.firstIndex(where: { $0["id"] as? String == before }) else {
                        return error(400, "invalid", "before must name a message in this thread.")
                    }
                    end = i
                }
                window = messages[max(0, end - limit)..<end]
            }
            let hasOlder = (window.startIndex > 0)
            let rows = window.map { row -> [String: Any] in
                var out = row
                let id = row["id"] as! String
                if let answer = answers[id] {
                    out["answer"] = answer
                    out["answered"] = true
                } else {
                    out["answer"] = NSNull()
                    out["answered"] = false
                }
                return out
            }
            return ok([
                "thread": ["id": "demo-thread", "unread_for_tester": unread],
                "tester": profile(suggested: nil),
                "messages": rows,
                "hasOlder": hasOlder,
            ])
        }
    }

    private func send(_ json: [String: Any]) -> Reply {
        lock.withLock {
            if _removed { return removedReply() }
            let nonce = json["clientNonce"] as? String ?? UUID().uuidString
            // A retry of something that already landed: keep the first copy.
            if nonces.contains(nonce) { return Reply(status: 200, body: data(["duplicate": true])) }
            nonces.insert(nonce)
            let text = json["text"] as? String ?? ""
            let ids = json["attachmentIds"] as? [String] ?? []
            let row = insert(direction: "inbound", origin: "direct", type: "text",
                             payload: ["text": text], at: Date(),
                             attachments: ids.compactMap(attachmentJSON))
            return Reply(status: 201, body: data(["message": row]))
        }
    }

    private func respond(_ id: String, _ json: [String: Any]) -> Reply {
        lock.withLock {
            if _removed { return removedReply() }
            guard let card = messages.first(where: { $0["id"] as? String == id }),
                  card["direction"] as? String == "outbound" else {
                return error(404, "not_found", "No such card.")
            }
            if answers[id] != nil {
                return error(409, "already_answered", "Already answered.")
            }
            let payload = card["payload"] as? [String: Any] ?? [:]
            let echo: String
            switch card["type"] as? String {
            case "poll":
                let options = payload["options"] as? [String] ?? []
                let picked = (json["selected"] as? [Int] ?? []).filter(options.indices.contains)
                guard !picked.isEmpty else { return error(400, "invalid", "Pick an option.") }
                echo = picked.map { options[$0] }.joined(separator: ", ")
                answers[id] = ["kind": "poll", "selected": picked]
            case "test_request":
                let outcome = json["outcome"] as? String
                guard outcome == "passed" || outcome == "failed" else {
                    return error(400, "invalid", "outcome must be passed or failed.")
                }
                echo = outcome == "passed" ? "It worked" : "Something broke"
                answers[id] = ["kind": "test_request", "outcome": outcome!]
            default:
                return error(400, "invalid", "This card cannot be answered.")
            }
            // The service writes the answer into the thread as the tester's own
            // words, which is what replaces the echo the client showed while it
            // was queued.
            let row = insert(direction: "inbound", origin: "direct", type: "text",
                             payload: ["text": echo], at: Date())
            return Reply(status: 201, body: data(["response": answers[id]!, "message": row]))
        }
    }

    private func attach(_ request: URLRequest, body: Data) -> Reply {
        lock.withLock {
            if _removed { return removedReply() }
            let (fileName, mime, bytes) = Self.firstPart(of: body, contentType:
                request.value(forHTTPHeaderField: "Content-Type") ?? "")
            guard let bytes, !bytes.isEmpty else { return error(400, "invalid", "No file.") }
            let id = "file-\(nextId)"
            nextId += 1
            files[id] = bytes
            fileTypes[id] = mime ?? "image/jpeg"
            var attachment = attachmentJSON(id) ?? [:]
            attachment["originalMime"] = Self.orNull(mime)
            attachment["filename"] = Self.orNull(fileName)
            return Reply(status: 201, body: data(["attachment": attachment]))
        }
    }

    // MARK: - Pieces

    @discardableResult
    private func insert(
        direction: String, origin: String, type: String, payload: [String: Any],
        at: Date, attachments: [[String: Any]] = []
    ) -> [String: Any] {
        let row: [String: Any] = [
            "id": "msg-\(nextId)",
            "direction": direction,
            "origin": origin,
            "type": type,
            "payload": payload,
            "created_at": Self.timestamp.string(from: at),
            "attachments": attachments,
        ]
        nextId += 1
        messages.append(row)
        return row
    }

    /// Called with the lock held.
    private func attachmentJSON(_ id: String) -> [String: Any]? {
        guard let bytes = files[id] else { return nil }
        var out: [String: Any] = [
            "id": id, "mime": fileTypes[id] ?? "image/jpeg",
            "url": "/demo-files/\(id)", "bytes": bytes.count,
        ]
        // The service sends the picture's own size so the thread can hold its
        // shape while it loads, and the panel relies on that.
        #if canImport(UIKit)
        if let size = UIImage(data: bytes)?.size {
            out["width"] = Int(size.width)
            out["height"] = Int(size.height)
        }
        #endif
        return out
    }

    /// Called with the lock held.
    private func profile(suggested: String?) -> [String: Any] {
        let name = displayName
        return [
            "displayName": Self.orNull(name),
            "needsName": name == nil,
            "suggestedName": Self.orNull(name ?? suggested),
        ]
    }

    private static func orNull(_ value: String?) -> Any {
        if let value { return value }
        return NSNull()
    }

    private func removedReply() -> Reply {
        error(403, "removed", "You are no longer part of this testing programme.")
    }

    private func ok(_ object: [String: Any]) -> Reply {
        Reply(status: 200, body: data(object))
    }

    private func error(_ status: Int, _ code: String, _ message: String) -> Reply {
        Reply(status: status, body: data(["code": code, "message": message]))
    }

    private func data(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// The first part of a multipart body: its filename, type and bytes.
    private static func firstPart(of body: Data, contentType: String) -> (String?, String?, Data?) {
        guard let range = contentType.range(of: "boundary=") else { return (nil, nil, nil) }
        let boundary = Data("--\(contentType[range.upperBound...])".utf8)
        let separator = Data("\r\n\r\n".utf8)
        guard let first = body.range(of: boundary),
              let headersEnd = body.range(of: separator, in: first.upperBound..<body.endIndex),
              let next = body.range(of: boundary, in: headersEnd.upperBound..<body.endIndex)
        else { return (nil, nil, nil) }
        let headers = String(decoding: body[first.upperBound..<headersEnd.lowerBound], as: UTF8.self)
        var fileName: String?
        var mime: String?
        for line in headers.components(separatedBy: "\r\n") {
            if let r = line.range(of: "filename=\"") {
                fileName = String(line[r.upperBound...].prefix { $0 != "\"" })
            }
            if line.lowercased().hasPrefix("content-type:") {
                mime = line.dropFirst("content-type:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        // The part ends with CRLF before the next boundary.
        let end = max(headersEnd.upperBound, next.lowerBound - 2)
        return (fileName, mime, body.subdata(in: headersEnd.upperBound..<end))
    }

    private static let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let teamLines = [
        "Build 1.4 (212) is out — the new checkout is behind the basket icon.",
        "Thanks, that crash is fixed in the next build.",
        "Could you try search again? We changed how results load.",
        "We shipped the dark mode fix you asked for.",
        "Quick one: does the app feel faster since yesterday?",
        "Good catch — logged it for the next sprint.",
        "We're testing a new onboarding. Tell us if anything is confusing.",
    ]

    private static let testerLines = [
        "Checkout froze on the payment step, twice.",
        "Search is much quicker now, nice.",
        "The wishlist button is hard to hit on my phone.",
        "Dark mode looks great!",
        "Found a typo on the order confirmation screen.",
    ]
}

/// Hands requests for `FakeService.host` to the fake, after `latency`.
final class FakeURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == FakeService.host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let service = FakeService.shared
        let request = self.request
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        DispatchQueue.global().asyncAfter(deadline: .now() + service.latency) { [weak self] in
            guard let self else { return }
            if service.offline {
                self.client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let reply = service.handle(request, body: body)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": reply.contentType])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = reply.body { self.client?.urlProtocol(self, didLoad: data) }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// URLSession moves a request's body into a stream before a protocol sees it.
    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            out.append(buffer, count: n)
        }
        return out
    }
}
