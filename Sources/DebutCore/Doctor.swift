import Foundation

public struct SignatureFacts: Equatable, Sendable {
    public var isValid: Bool
    public var hasHardenedRuntime: Bool
    public var isAdHoc: Bool
    public var teamIdentifier: String?

    public init(isValid: Bool, hasHardenedRuntime: Bool, isAdHoc: Bool, teamIdentifier: String?) {
        self.isValid = isValid
        self.hasHardenedRuntime = hasHardenedRuntime
        self.isAdHoc = isAdHoc
        self.teamIdentifier = teamIdentifier
    }
}

public struct IconFacts: Equatable, Sendable {
    /// The share of pixels that differ from Apple's rounded square. Large values get a grey plate on macOS 26.
    public var shapeMismatch: Double

    public init(shapeMismatch: Double) {
        self.shapeMismatch = shapeMismatch
    }
}

/// One signable item inside an app: the app itself, a nested app, a framework or a library.
public struct CodeFacts: Equatable, Sendable {
    public enum Kind: Sendable { case app, nestedApp, library }

    public var name: String
    public var kind: Kind
    public var signature: SignatureFacts?
    public var icon: IconFacts?

    public init(name: String, kind: Kind, signature: SignatureFacts?, icon: IconFacts? = nil) {
        self.name = name
        self.kind = kind
        self.signature = signature
        self.icon = icon
    }
}

public struct CertificateFacts: Equatable, Sendable {
    public var name: String
    public var expires: Date

    public init(name: String, expires: Date) {
        self.name = name
        self.expires = expires
    }
}

public struct Finding: Equatable, Sendable {
    public enum Severity: Sendable { case problem, warning }

    public var severity: Severity
    public var message: String
    public var fix: String

    public init(severity: Severity, message: String, fix: String) {
        self.severity = severity
        self.message = message
        self.fix = fix
    }
}

public enum Doctor {
    public static let maximumShapeMismatch = 0.02
    public static let expiryWarningDays = 60.0

    /// Whether the app is ready to hand to users. Only applies to an app that's meant to be signed already.
    public static func examine(_ items: [CodeFacts], requireSignature: Bool) -> [Finding] {
        items.flatMap { examine($0, requireSignature: requireSignature) } + teamMismatch(in: items)
    }

    private static func examine(_ item: CodeFacts, requireSignature: Bool) -> [Finding] {
        var findings: [Finding] = []
        if item.kind != .library {
            findings += examineIcon(of: item)
        }
        guard requireSignature else { return findings }

        guard let signature = item.signature, !signature.isAdHoc else {
            return findings + [Finding(
                severity: .problem,
                message: "\(item.name) isn't signed with a Developer ID.",
                fix: "`debut release` signs it for you."
            )]
        }
        if !signature.isValid {
            findings.append(Finding(
                severity: .problem,
                message: "\(item.name) has a broken signature, usually because a file changed after signing.",
                fix: "`debut release` signs it again from the inside out."
            ))
        }
        if !signature.hasHardenedRuntime {
            findings.append(Finding(
                severity: .problem,
                message: "\(item.name) doesn't use the hardened runtime, so Apple will reject it.",
                fix: "`debut release` turns it on when signing."
            ))
        }
        return findings
    }

    private static func examineIcon(of item: CodeFacts) -> [Finding] {
        guard let icon = item.icon else {
            return [Finding(
                severity: .warning,
                message: "\(item.name) has no icon, so macOS shows a generic one for it.",
                fix: "Add an icon to its Resources and set CFBundleIconFile in its Info.plist."
            )]
        }
        guard icon.shapeMismatch <= maximumShapeMismatch else {
            let percent = Int((icon.shapeMismatch * 100).rounded())
            return [Finding(
                severity: .warning,
                message: "\(item.name)'s icon is \(percent)% off Apple's shape, so macOS 26 may put it on a grey plate.",
                fix: "Cut the artwork to a rounded square: 824 of 1024 pixels, with a corner radius of about 185."
            )]
        }
        return []
    }

    private static func teamMismatch(in items: [CodeFacts]) -> [Finding] {
        let teams = Set(items.compactMap { $0.signature?.teamIdentifier })
        guard teams.count > 1 else { return [] }
        return [Finding(
            severity: .problem,
            message: "Parts of the app are signed by different teams: \(teams.sorted().joined(separator: ", ")).",
            fix: "`debut release` signs everything with one identity."
        )]
    }

    public static func examine(certificates: [CertificateFacts], now: Date) -> [Finding] {
        guard !certificates.isEmpty else {
            return [Finding(
                severity: .problem,
                message: "This Apple account has no Developer ID Application certificate.",
                fix: "Run `debut setup`."
            )]
        }
        guard let newest = certificates.max(by: { $0.expires < $1.expires }) else { return [] }
        let days = newest.expires.timeIntervalSince(now) / 86_400
        if days < 0 {
            return [Finding(
                severity: .problem,
                message: "Your Developer ID certificate has expired.",
                fix: "Run `debut setup` to create a new one."
            )]
        }
        if days < expiryWarningDays {
            return [Finding(
                severity: .warning,
                message: "Your Developer ID certificate expires in \(Int(days)) days.",
                fix: "Run `debut setup` to create a new one before then."
            )]
        }
        return []
    }
}
