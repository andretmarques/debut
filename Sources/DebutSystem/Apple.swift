import CryptoKit
import DebutCore
import Foundation
import Security

public struct DebutError: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

public struct ShellResult {
    public let status: Int32
    public let output: String
}

public enum Shell {
    /// Standard error is merged into the output. Never pass a secret as an argument: other processes can see those.
    @discardableResult
    public static func run(_ tool: String, _ arguments: [String], directory: String? = nil, input: Data? = nil) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let directory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let inputPipe = input.map { _ in Pipe() }
        if let inputPipe {
            process.standardInput = inputPipe
        }
        try process.run()
        if let input, let inputPipe {
            inputPipe.fileHandleForWriting.write(input)
            try inputPipe.fileHandleForWriting.close()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ShellResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// For a project's own build command, whose output the developer wants to see.
    public static func runVisible(command: String, directory: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// An App Store Connect API key. The private key only lives in the Keychain, or in a short-lived private file.
public struct AppleKey: Codable {
    public let keyID: String
    public let issuerID: String
    public let privateKeyPEM: String

    public init(keyID: String, issuerID: String, privateKeyPEM: String) throws {
        guard (try? P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)) != nil else {
            throw DebutError("That file isn't an App Store Connect API key.")
        }
        self.keyID = keyID
        self.issuerID = issuerID
        self.privateKeyPEM = privateKeyPEM
    }

    func token() throws -> String {
        func encode(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let now = Int(Date().timeIntervalSince1970)
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"])
        let claims = try JSONSerialization.data(withJSONObject: [
            "iss": issuerID, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1",
        ] as [String: Any])
        let message = encode(header) + "." + encode(claims)
        let signature = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM).signature(for: Data(message.utf8))
        return message + "." + encode(signature.rawRepresentation)
    }

    /// Hands the key to `notarytool` in a private file, which is removed straight afterwards.
    func withKeyFile<T>(_ body: (String) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("debut-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("AuthKey_\(keyID).p8")
        FileManager.default.createFile(atPath: file.path, contents: Data(privateKeyPEM.utf8), attributes: [.posixPermissions: 0o600])
        return try body(file.path)
    }
}

public enum KeyStore {
    private static let service = "app.debut.apple-key"

    public static func save(_ key: AppleKey) throws {
        delete()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.keyID,
            kSecValueData as String: try JSONEncoder().encode(key),
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw DebutError("Couldn't save the key to your Keychain (error \(status)).") }
    }

    public static func load() -> AppleKey? {
        fromEnvironment() ?? fromKeychain()
    }

    /// On a CI machine, the key comes from the repo's secrets.
    private static func fromEnvironment() -> AppleKey? {
        let environment = ProcessInfo.processInfo.environment
        guard let keyID = environment[CISecrets.keyID], let issuerID = environment[CISecrets.issuerID],
              let encoded = environment[CISecrets.key], let data = Data(base64Encoded: encoded),
              let pem = String(data: data, encoding: .utf8)
        else { return nil }
        return try? AppleKey(keyID: keyID, issuerID: issuerID, privateKeyPEM: pem)
    }

    private static func fromKeychain() -> AppleKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(AppleKey.self, from: data)
    }

    public static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

public struct AppleAPI {
    private static let developerIDTypes: Set<String> = ["DEVELOPER_ID_APPLICATION", "DEVELOPER_ID_APPLICATION_G2"]
    private let key: AppleKey

    public init(key: AppleKey) {
        self.key = key
    }

    public func developerIDCertificates() async throws -> [CertificateFacts] {
        var request = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com/v1/certificates?limit=200")!)
        request.setValue("Bearer \(try key.token())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 401 {
                throw DebutError("Apple didn't accept this key. Check the Issuer ID, and that the key is under Team Keys and hasn't been revoked.")
            }
            throw DebutError("Apple's API returned HTTP \(status).")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = json?["data"] as? [[String: Any]] ?? []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return items.compactMap { item in
            guard let attributes = item["attributes"] as? [String: Any],
                  let type = attributes["certificateType"] as? String, Self.developerIDTypes.contains(type),
                  let text = attributes["expirationDate"] as? String, let expires = formatter.date(from: text)
            else { return nil }
            return CertificateFacts(name: attributes["name"] as? String ?? "Developer ID Application", expires: expires)
        }
    }
}

public enum Notary {
    /// Reads history, the lightest call that proves the key can notarize.
    public static func canAuthenticate(_ key: AppleKey) throws -> Bool {
        try key.withKeyFile { path in
            try Shell.run("/usr/bin/xcrun", ["notarytool", "history", "--key", path, "--key-id", key.keyID, "--issuer", key.issuerID, "--output-format", "json"]).status == 0
        }
    }

    public static func notarizeAndStaple(_ file: String, key: AppleKey) throws {
        try key.withKeyFile { path in
            let credentials = ["--key", path, "--key-id", key.keyID, "--issuer", key.issuerID]
            let submit = try Shell.run("/usr/bin/xcrun", ["notarytool", "submit", file] + credentials + ["--wait", "--output-format", "json"])
            let json = (try? JSONSerialization.jsonObject(with: Data(submit.output.utf8))) as? [String: Any]
            guard json?["status"] as? String == "Accepted" else {
                var message = "Apple didn't accept the app (\(json?["status"] as? String ?? "no answer"))."
                if let id = json?["id"] as? String {
                    let log = try Shell.run("/usr/bin/xcrun", ["notarytool", "log", id] + credentials)
                    message += "\n\(log.output)"
                } else {
                    message += "\n\(submit.output)"
                }
                throw DebutError(message)
            }
        }
        let staple = try Shell.run("/usr/bin/xcrun", ["stapler", "staple", file])
        guard staple.status == 0 else { throw DebutError("Couldn't attach Apple's ticket:\n\(staple.output)") }
    }
}

public enum SigningKeychain {
    public static func developerIDs() throws -> [String] {
        let result = try Shell.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
        return SigningIdentities.developerIDs(inFindIdentityOutput: result.output)
    }
}

public enum CISigning {
    /// Exports one identity only: `security export` would include everything in the Keychain.
    public static func exportCertificate(named name: String, password: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let identities = result as? [SecIdentity] else {
            throw DebutError("Couldn't read your signing identities.")
        }
        let wanted = name
        let match = identities.first { identity in
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return false }
            return SecCertificateCopySubjectSummary(certificate) as String? == wanted
        }
        guard let match else { throw DebutError("Couldn't find \(name) in your Keychain.") }

        var parameters = SecItemImportExportKeyParameters(
            version: UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION),
            flags: [],
            passphrase: Unmanaged.passUnretained(password as CFString as AnyObject),
            alertTitle: nil,
            alertPrompt: nil,
            accessRef: nil,
            keyUsage: nil,
            keyAttributes: nil
        )
        var exported: CFData?
        let status = SecItemExport(match, .formatPKCS12, [], &parameters, &exported)
        guard status == errSecSuccess, let exported else {
            throw DebutError("macOS didn't allow exporting the certificate (error \(status)). If it asked for permission, choose Allow and run this again.")
        }
        return exported as Data
    }

    public static func randomPassword() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw DebutError("Couldn't generate a password.")
        }
        return Data(bytes).base64EncodedString()
    }

    /// A throwaway keychain for one CI run, so the certificate never touches anything lasting.
    public static func prepareTemporaryKeychain() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CI"] == "true" else {
            throw DebutError("This only runs on a CI machine, because it changes which keychains are in use.")
        }
        guard let encoded = environment[CISecrets.certificate], let certificate = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              let certificatePassword = environment[CISecrets.certificatePassword]
        else { throw DebutError("\(CISecrets.certificate) and \(CISecrets.certificatePassword) aren't set. Run `debut setup --github <repo>` on your Mac.") }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("debut-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("certificate.p12")
        FileManager.default.createFile(atPath: file.path, contents: certificate, attributes: [.posixPermissions: 0o600])

        let keychain = "debut-build.keychain"
        let password = try randomPassword()
        let security = "/usr/bin/security"
        let steps: [[String]] = [
            ["create-keychain", "-p", password, keychain],
            ["set-keychain-settings", "-lut", "21600", keychain],
            ["unlock-keychain", "-p", password, keychain],
            ["import", file.path, "-k", keychain, "-P", certificatePassword, "-T", "/usr/bin/codesign"],
            ["set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", password, keychain],
            ["list-keychains", "-d", "user", "-s", keychain, "login.keychain"],
            ["default-keychain", "-s", keychain],
        ]
        for step in steps {
            let result = try Shell.run(security, step)
            guard result.status == 0 else { throw DebutError("`security \(step[0])` failed. The certificate secrets may be wrong.") }
        }
    }
}

/// The certificate step Apple only allows in the browser: prepare the request, then catch the download.
public enum CertificateRequest {
    public static let applePage = "https://developer.apple.com/account/resources/certificates/add"

    public struct Prepared {
        public let directory: URL
        public let keyFile: String
        public let requestFile: String
    }

    public static func prepare(in directory: URL) throws -> Prepared {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let keyFile = directory.appendingPathComponent("developer-id.key").path
        let requestFile = directory.appendingPathComponent("DeveloperID.certSigningRequest").path
        guard try Shell.run("/usr/bin/openssl", ["genrsa", "-out", keyFile, "2048"]).status == 0,
              try Shell.run("/usr/bin/openssl", ["req", "-new", "-key", keyFile, "-subj", "/CN=Developer ID Application", "-out", requestFile]).status == 0
        else { throw DebutError("Couldn't prepare the certificate request.") }
        return Prepared(directory: directory, keyFile: keyFile, requestFile: requestFile)
    }

    /// Waits for a certificate that's newer than `since`, in the given folder.
    public static func waitForDownload(in folder: URL, since: Date, timeout: TimeInterval) -> URL? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
            if let found = files.first(where: { url in
                url.pathExtension == "cer" && ((try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast) > since
            }) {
                return found
            }
            Thread.sleep(forTimeInterval: 2)
        }
        return nil
    }

    public static func install(keyFile: String, certificate: URL) throws {
        for file in [keyFile, certificate.path] {
            let result = try Shell.run("/usr/bin/security", ["import", file, "-T", "/usr/bin/codesign"])
            guard result.status == 0 else { throw DebutError("Couldn't add it to your Keychain:\n\(result.output)") }
        }
    }
}
