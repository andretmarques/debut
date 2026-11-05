import Foundation

/// What a project declares in `debut.json`. Every value can also come from a command-line option.
public struct ProjectConfig: Codable, Equatable, Sendable {
    public var app: String?
    public var build: String?
    public var repository: String?

    public init(app: String? = nil, build: String? = nil, repository: String? = nil) {
        self.app = app
        self.build = build
        self.repository = repository
    }
}

public struct ReleaseVersion: Equatable, Sendable {
    public let version: String

    /// `1.2.3`, `alpha-1.1` or `beta-2`. Plain numbers get a `v` on their tag.
    public init?(_ text: String) {
        let pattern = #"^((alpha|beta)-\d+(\.\d+)*|\d+\.\d+\.\d+)$"#
        guard text.range(of: pattern, options: .regularExpression) != nil else { return nil }
        version = text
    }

    public var tag: String {
        version.first?.isNumber == true ? "v\(version)" : version
    }
}

public struct ReleaseNotes: Equatable, Sendable {
    public let codename: String?
    public let body: String

    /// A first line of `# Codename` names the release, and the rest describes it.
    public init(markdown: String) {
        let lines = markdown.components(separatedBy: .newlines)
        if let first = lines.first, first.hasPrefix("# ") {
            codename = first.dropFirst(2).trimmingCharacters(in: .whitespaces)
            body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            codename = nil
            body = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public func title(appName: String, version: ReleaseVersion) -> String {
        let base = "\(appName) \(version.version)"
        return codename.map { "\(base) · \($0)" } ?? base
    }
}

public enum Credentials {
    /// Apple names key files `AuthKey_<Key ID>.p8`.
    public static func keyID(fromFileName name: String) -> String? {
        let pattern = #"^AuthKey_([A-Z0-9]{8,12})\.p8$"#
        guard let range = name.range(of: pattern, options: .regularExpression) else { return nil }
        return String(name[range].dropFirst("AuthKey_".count).dropLast(".p8".count))
    }

    public static func isIssuerID(_ text: String) -> Bool {
        UUID(uuidString: text) != nil
    }
}

public enum SigningIdentities {
    /// Reads the names of Developer ID Application identities from `security find-identity` output.
    public static func developerIDs(inFindIdentityOutput output: String) -> [String] {
        output.components(separatedBy: .newlines).compactMap { line in
            guard let start = line.firstIndex(of: "\""), let end = line.lastIndex(of: "\""), start < end else { return nil }
            let name = String(line[line.index(after: start)..<end])
            return name.hasPrefix("Developer ID Application:") ? name : nil
        }
    }
}

public enum PythonLiteral {
    /// A quoted string for dmgbuild's settings file, so paths and names with quotes can't break it.
    public static func string(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

public enum ReleaseAsset {
    /// GitHub renames uploads with spaces, which would break the download link and the final check.
    public static func fileName(appName: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let safe = appName.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        return "\(safe).dmg"
    }
}

/// The names used between `debut setup --github`, the GitHub Action and a CI run.
public enum CISecrets {
    public static let keyID = "DEBUT_KEY_ID"
    public static let issuerID = "DEBUT_ISSUER_ID"
    public static let key = "DEBUT_KEY"
    public static let certificate = "DEBUT_CERT_P12"
    public static let certificatePassword = "DEBUT_CERT_PASSWORD"
}
