import Foundation

// MARK: - Wire types
//
// Field names on the wire are the database's own snake_case for anything the
// service SELECTs, and camelCase for values it assembles — an attachment, the
// tester profile, `hasOlder`. That split is deliberate and documented in
// CLAUDE.md, so the CodingKeys below are per-type rather than one global
// key-decoding strategy: a strategy would have to be wrong for one half.

/// One message in the thread.
public struct Message: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    /// `inbound` is the tester, `outbound` is the company.
    ///
    /// The tester's own words go on the *right* here, which is the opposite of
    /// where the console puts them — both surfaces are read by somebody who
    /// expects their own words on the right, and making the two agree would put
    /// one of them backwards.
    public let direction: String
    /// `direct`, `broadcast`, or `system`.
    public let origin: String
    /// `text`, `system`, `poll`, `test_request` — and possibly something this
    /// build has never heard of, which is why `CardKind` has an `unknown` case.
    public let type: String
    public let payload: Payload?
    public let createdAt: Date
    public let answer: Answer?
    public let answered: Bool?
    public let attachments: [Attachment]?

    enum CodingKeys: String, CodingKey {
        case id, direction, origin, type, payload, answer, answered, attachments
        case createdAt = "created_at"
    }

    public var kind: CardKind { CardKind(rawValue: type) }
    public var isFromTester: Bool { direction == "inbound" }
    public var isSystem: Bool { origin == "system" }

    /// What a plain bubble shows. A card falls back to its own first line so an
    /// unknown type still reads as something rather than as an empty box.
    public var bodyText: String {
        payload?.text ?? payload?.title ?? payload?.question ?? ""
    }
}

/// The card vocabulary, with a case for the one that has not been invented yet.
///
/// An older client meeting a newer card shows its summary and a line saying to
/// update — that degradation is the whole reason a new card type can ship before
/// every tester has taken an update.
public enum CardKind: Equatable, Sendable {
    case text, system, poll, testRequest
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "text": self = .text
        case "system": self = .system
        case "poll": self = .poll
        case "test_request": self = .testRequest
        default: self = .unknown(rawValue)
        }
    }

    var isCard: Bool {
        switch self {
        case .poll, .testRequest: return true
        default: return false
        }
    }

    var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }
}

/// Everything any card type puts in `payload`, all optional.
///
/// Decoding into optionals rather than a per-type enum is what lets an unknown
/// card arrive without throwing: the fields this build does not know about are
/// simply absent, and the ones it does know about still render.
public struct Payload: Codable, Equatable, Sendable {
    public let text: String?
    public let title: String?
    public let question: String?
    public let options: [String]?
    public let steps: [String]?
    public let multiSelect: Bool?
}

/// A tester's recorded answer to a card.
public struct Answer: Codable, Equatable, Sendable {
    public let kind: String?
    public let selected: [Int]?
    public let outcome: String?
}

/// An uploaded image, as the service hands it back.
///
/// `url` is signed and expires in thirty minutes, so it is not something to
/// cache: re-reading the window is what mints fresh ones. `originalMime`
/// remembers what actually arrived — an iPhone sends HEIC and the service
/// stores JPEG, and an operator seeing `image/jpeg` with no other record would
/// have no way to know that.
public struct Attachment: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let mime: String
    public let originalMime: String?
    public let bytes: Int?
    public let width: Int?
    public let height: Int?
    public let filename: String?
    public let url: String

    /// The picture's own shape, so the thread reserves the right space and does
    /// not jump about while images load.
    public var aspectRatio: Double? {
        guard let w = width, let h = height, w > 0, h > 0 else { return nil }
        return Double(w) / Double(h)
    }
}

/// What the tester has said about their own name, and whether they have.
public struct TesterProfile: Codable, Equatable, Sendable {
    public let displayName: String?
    public let needsName: Bool
    /// What `traits.name` already says — a suggestion to pre-fill the box with,
    /// never an answer. What a company has on file and what somebody wants to be
    /// called in a conversation are different questions.
    public let suggestedName: String?
}

/// The host app's own name and branding, as configured in the console.
public struct AppInfo: Codable, Equatable, Sendable {
    public let name: String
    public let appearance: Appearance?
    /// Every language at once, keyed by locale tag, so a host with its own
    /// language switch changes language without a new handshake.
    public let strings: [String: [String: String]]?
    public let defaultLocale: String?

    enum CodingKeys: String, CodingKey {
        case name, appearance, strings
        case defaultLocale = "default_locale"
    }
}

// MARK: - Responses

struct IdentifyResponse: Decodable {
    let session: String
    let app: AppInfo
    let tester: TesterProfile?
}

struct ThreadResponse: Decodable {
    struct ThreadMeta: Decodable {
        let id: String
        let unreadForTester: Int

        enum CodingKeys: String, CodingKey {
            case id
            case unreadForTester = "unread_for_tester"
        }
    }
    let thread: ThreadMeta?
    let tester: TesterProfile?
    let messages: [Message]
    let hasOlder: Bool
}

struct UnreadResponse: Decodable { let unread: Int }
struct AttachmentResponse: Decodable { let attachment: Attachment }
struct ProfileResponse: Decodable { let tester: TesterProfile }

// MARK: - Errors

/// An error from the service, carrying the two things a client has to branch on.
///
/// `code` and `status`, never the sentence: the prose is written for a developer
/// reading a log and is reworded whenever somebody finds a better sentence, so a
/// client that matches on the English breaks silently the first time it improves.
public struct TesterChannelError: Error, LocalizedError, Equatable, Sendable {
    public let status: Int
    public let code: String?
    public let message: String

    public var errorDescription: String? { message }

    /// The tester has been taken out of the programme (D17). Final — reading
    /// still works, writing does not, and identifying again will not undo it.
    public var isRemoved: Bool { status == 403 && code == "removed" }

    /// The session no longer verifies. The answer is to identify again, which
    /// means a round trip to your own backend for a fresh `userHash`.
    public var isUnauthorized: Bool { status == 401 }

    /// This card already carries this tester's answer.
    ///
    /// **This is success.** A queued retry that raced the first attempt lands
    /// here, and it means the answer *is* recorded. Treating it as a failure
    /// shows somebody an error for a tap that worked.
    public var isAlreadyAnswered: Bool { status == 409 && code == "already_answered" }
}

/// Anything that went wrong before a response existed — no network, a DNS
/// failure, a body that would not decode. Kept separate from the above because
/// a queued message should be retried on one and not on the other.
public struct TesterChannelTransportError: Error, LocalizedError, Sendable {
    public let underlying: Error
    public var errorDescription: String? { underlying.localizedDescription }
}
