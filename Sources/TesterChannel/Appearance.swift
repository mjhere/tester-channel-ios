import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The host app's own colours and type.
///
/// It is configuration, not code: a customer restyles the thread in the console
/// and nothing in their app changes. Testers pick it up at their next handshake.
/// Worth saying plainly because the opposite is the natural assumption — this is
/// something they linked into their project, so changing how it looks feels like
/// it should mean shipping a new build.
public struct Appearance: Codable, Equatable, Sendable {
    public var accent: String?
    public var surface: String?
    public var notice: String?
    public var cornerRadius: Double?
    public var fontFamily: String?
    public var teamName: String?
    public var teamAvatarUrl: String?

    public init(
        accent: String? = nil, surface: String? = nil, notice: String? = nil,
        cornerRadius: Double? = nil, fontFamily: String? = nil,
        teamName: String? = nil, teamAvatarUrl: String? = nil
    ) {
        self.accent = accent
        self.surface = surface
        self.notice = notice
        self.cornerRadius = cornerRadius
        self.fontFamily = fontFamily
        self.teamName = teamName
        self.teamAvatarUrl = teamAvatarUrl
    }
}

/// The resolved palette the views actually draw with.
///
/// Mirrors the defaults in `#mountShell` in `sdk/web/tester-channel.js`, which
/// stays the authority. The web client, the console's appearance editor and this
/// each hold their own copy because none of them can import from the others;
/// `test/appearance.test.ts` holds all three together — it reads the hex strings
/// below, which is why they are written as strings rather than as colour
/// components. `fontFamily` is the one it cannot compare: the web default is a CSS
/// stack and this reads a stack as a list, so there is no single value it could be
/// said to default to.
public struct ResolvedAppearance: Equatable, Sendable {
    public var accent: Color
    public var surface: Color
    public var notice: Color
    public var cornerRadius: CGFloat
    public var fontName: String?
    public var teamName: String
    public var teamAvatarUrl: URL?

    /// Ink. Fixed rather than derived from `surface`, exactly as in the web
    /// client: the surface arrives as a customer's own string in any CSS colour
    /// format, and guessing a contrasting foreground from something we may have
    /// failed to parse is worse than one dark value that works on the light
    /// surfaces this is designed for.
    public static let ink = Color(red: 0x16 / 255, green: 0x18 / 255, blue: 0x1a / 255)

    // Written as the same hex strings the web client and the console's editor
    // hold, rather than as colour components, so `test/appearance.test.ts` can
    // read them and fail when the three copies drift. Components would have
    // made this the one copy nothing could check.
    public static let defaultAccentHex = "#1E5B4E"
    public static let defaultSurfaceHex = "#FFFFFF"
    public static let defaultNoticeHex = "#CBEA56"
    public static let defaultCornerRadius: CGFloat = 12

    static let defaultAccent = Color(hex: defaultAccentHex) ?? .black
    static let defaultSurface = Color(hex: defaultSurfaceHex) ?? .white
    static let defaultNotice = Color(hex: defaultNoticeHex) ?? .yellow

    public init(_ a: Appearance?, appName: String) {
        accent = Color(hex: a?.accent) ?? Self.defaultAccent
        surface = Color(hex: a?.surface) ?? Self.defaultSurface
        notice = Color(hex: a?.notice) ?? Self.defaultNotice
        cornerRadius = a?.cornerRadius.map { CGFloat($0) } ?? Self.defaultCornerRadius
        // A CSS font stack means nothing to UIKit. The first family in it that
        // the device actually has is the closest honest reading, and falling
        // back to the system face is better than rendering in something the
        // customer did not choose because the first name in their stack was
        // "system-ui".
        fontName = Self.firstAvailableFamily(a?.fontFamily)
        let name = (a?.teamName?.trimmed).flatMap { $0.isEmpty ? nil : $0 } ?? appName
        teamName = name
        teamAvatarUrl = (a?.teamAvatarUrl).flatMap { URL(string: $0) }
    }

    /// The header's fallback when there is no avatar image.
    ///
    /// The first *letter*, not the first character: an app called "1000 Fans"
    /// wore a small dark circle with a 1 in it, which reads as an unread count.
    public var monogram: String {
        let letter = teamName.first(where: { $0.isLetter })
            ?? teamName.trimmed.first
        return String(letter ?? "?").uppercased()
    }

    private static func firstAvailableFamily(_ stack: String?) -> String? {
        guard let stack, !stack.isEmpty else { return nil }
        #if canImport(UIKit)
        let available = Set(UIFont.familyNames)
        for raw in stack.split(separator: ",") {
            let name = raw.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if available.contains(name) { return name }
        }
        #endif
        return nil
    }
}

extension Color {
    /// `#RGB`, `#RRGGBB` and `#RRGGBBAA`, which is what the console's own
    /// validator accepts. Anything else — `rgb()`, a named colour, a gradient
    /// somebody pasted — returns nil and the caller keeps its default rather
    /// than drawing something nobody chose.
    init?(hex: String?) {
        guard var s = hex?.trimmed, s.hasPrefix("#") else { return nil }
        s.removeFirst()
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let r = Double((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(v & 0xFF) / 255 : 1
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
