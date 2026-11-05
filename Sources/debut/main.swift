import AppKit
import DebutCore
import DebutSystem
import Foundation

let usage = """
Debut: release your Mac app outside the App Store.

  debut setup    [--key <AuthKey_XXXX.p8>] [--issuer <id>] [--github <owner/name>]
  debut doctor   [--app <path>] [--before-signing]
  debut release  <version> [--app <path>] [--build <command>] [--repo <owner/name>]
                 [--notes <file>] [--output <file.dmg>] [--no-publish]

Project defaults can live in debut.json: {"app": "...", "build": "...", "repository": "..."}
"""

func option(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

func flag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

func step(_ text: String) { print("▶ \(text)") }
func done(_ text: String) { print("  ✓ \(text)") }

func ask(_ question: String) -> String? {
    print(question, terminator: " ")
    return readLine()?.trimmingCharacters(in: .whitespaces)
}

let workingDirectory = FileManager.default.currentDirectoryPath

func loadConfig() throws -> ProjectConfig {
    let file = URL(fileURLWithPath: workingDirectory).appendingPathComponent("debut.json")
    guard let data = try? Data(contentsOf: file) else { return ProjectConfig() }
    do {
        return try JSONDecoder().decode(ProjectConfig.self, from: data)
    } catch {
        throw DebutError("debut.json isn't valid: \(error.localizedDescription)")
    }
}

func requireKey() throws -> AppleKey {
    guard let key = KeyStore.load() else { throw DebutError("No Apple key yet. Run `debut setup` first.") }
    return key
}

func requireApp(_ config: ProjectConfig) throws -> AppBundle {
    guard let path = option("--app") ?? config.app else {
        throw DebutError("Which app? Use --app <path>, or set \"app\" in debut.json.")
    }
    return try AppBundle(path: path)
}

@discardableResult
func report(_ findings: [Finding]) -> Bool {
    for finding in findings {
        print("\(finding.severity == .problem ? "  ✗" : "  !") \(finding.message)")
        print("    \(finding.fix)")
    }
    return !findings.contains { $0.severity == .problem }
}

// MARK: setup

func findKeyFile() -> URL? {
    let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    let files = (try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil)) ?? []
    return files.first { Credentials.keyID(fromFileName: $0.lastPathComponent) != nil }
}

func waitForKeyFile() -> URL? {
    if let found = findKeyFile() { return found }
    NSWorkspace.shared.open(URL(string: "https://appstoreconnect.apple.com/access/integrations/api")!)
    print("  Opening Apple's page. Under Team Keys, click Generate API Key, choose the Developer role, then download it.")
    print("  Waiting for the download…")
    let deadline = Date().addingTimeInterval(600)
    while Date() < deadline {
        if let found = findKeyFile() { return found }
        Thread.sleep(forTimeInterval: 2)
    }
    return nil
}

func readIssuer() throws -> String {
    if let given = option("--issuer") {
        guard Credentials.isIssuerID(given) else {
            throw DebutError("That isn't an Issuer ID. It's the long one with dashes, above the key list. The short code is the Key ID.")
        }
        return given
    }
    while let answer = ask("  Paste the Issuer ID shown above the key list:") {
        if Credentials.isIssuerID(answer) { return answer }
        print("  That isn't it. The Issuer ID is the long one with dashes. The short code is the Key ID.")
    }
    throw DebutError("No Issuer ID given.")
}

func setUpKey() throws -> AppleKey {
    if let existing = KeyStore.load(), option("--key") == nil, (try? Notary.canAuthenticate(existing)) == true {
        done("Your Apple key \(existing.keyID) still works")
        return existing
    }
    let file = try option("--key").map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
        ?? { () throws -> URL in
            guard let found = waitForKeyFile() else { throw DebutError("Didn't find a downloaded AuthKey file. Run `debut setup` again.") }
            return found
        }()
    guard let keyID = Credentials.keyID(fromFileName: file.lastPathComponent) else {
        throw DebutError("Expected a file named AuthKey_XXXX.p8, as Apple names it.")
    }
    guard let pem = try? String(contentsOf: file, encoding: .utf8) else { throw DebutError("Can't read \(file.path).") }
    done("Found \(file.lastPathComponent)")

    let key = try AppleKey(keyID: keyID, issuerID: try readIssuer(), privateKeyPEM: pem)
    guard try Notary.canAuthenticate(key) else {
        throw DebutError("Apple didn't accept this key for notarizing. Check the Issuer ID, and that it's under Team Keys, not your personal keys.")
    }
    done("Apple accepted the key for notarizing")
    try KeyStore.save(key)
    done("Saved it in your Keychain")
    print("  Apple won't let you download that key file again, so keep a safe copy or delete it: \(file.path)")
    return key
}

func setUpCertificate() throws {
    let identities = try SigningKeychain.developerIDs()
    if let identity = identities.first {
        done("Signing with \(identity)")
        return
    }
    print("  There's no Developer ID certificate on this Mac, and Apple only lets you create one in the browser.")
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Debut/request")
    let prepared = try CertificateRequest.prepare(in: support)
    defer { try? FileManager.default.removeItem(at: prepared.directory) }
    let started = Date()
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: prepared.requestFile)])
    NSWorkspace.shared.open(URL(string: CertificateRequest.applePage)!)
    print("  1. On Apple's page, choose Developer ID Application, then G2 Sub-CA.")
    print("  2. Upload the file now selected in Finder.")
    print("  3. Download the certificate. Waiting for it…")
    let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    guard let certificate = CertificateRequest.waitForDownload(in: downloads, since: started, timeout: 900) else {
        throw DebutError("Didn't see a certificate download. Run `debut setup` again.")
    }
    try CertificateRequest.install(keyFile: prepared.keyFile, certificate: certificate)
    guard let identity = try SigningKeychain.developerIDs().first else {
        throw DebutError("The certificate was added, but macOS doesn't see it as a signing identity yet. Check that it's Developer ID Application.")
    }
    done("Installed \(identity)")
}

func setUpGitHub(repository: String, key: AppleKey) throws {
    step("GitHub secrets for \(repository)")
    guard let identity = try SigningKeychain.developerIDs().first else { throw DebutError("No Developer ID certificate to add.") }
    print("  If macOS asks to export your signing key, choose Allow.")
    let password = try CISigning.randomPassword()
    let certificate = try CISigning.exportCertificate(named: identity, password: password)
    let secrets: [(String, String)] = [
        (CISecrets.keyID, key.keyID),
        (CISecrets.issuerID, key.issuerID),
        (CISecrets.key, Data(key.privateKeyPEM.utf8).base64EncodedString()),
        (CISecrets.certificate, certificate.base64EncodedString()),
        (CISecrets.certificatePassword, password),
    ]
    for (name, value) in secrets {
        try GitHubSecrets.set(name, to: value, repository: repository)
        done(name)
    }
}

func runSetup() async throws {
    step("Apple access key")
    let key = try setUpKey()
    step("Signing certificate")
    try setUpCertificate()
    let certificates = try await AppleAPI(key: key).developerIDCertificates()
    report(Doctor.examine(certificates: certificates, now: Date()))
    if let repository = option("--github") {
        try setUpGitHub(repository: repository, key: key)
    }
    print("\nDone. Next: debut doctor, then debut release <version>")
}

// MARK: doctor

func runDoctor() async throws {
    let config = try loadConfig()
    var isHealthy = true

    if KeyStore.load() != nil || option("--app") != nil || config.app != nil {
        if let key = KeyStore.load() {
            step("Your Apple account")
            let findings = Doctor.examine(certificates: try await AppleAPI(key: key).developerIDCertificates(), now: Date())
            isHealthy = report(findings) && isHealthy
            if findings.isEmpty { done("Developer ID certificate is valid") }
        } else {
            print("! No Apple key saved yet, so your account wasn't checked. Run `debut setup`.")
        }
    }
    if option("--app") != nil || config.app != nil {
        let app = try requireApp(config)
        step("\(app.url.lastPathComponent)")
        let items = app.facts()
        let findings = Doctor.examine(items, requireSignature: !flag("--before-signing"))
        isHealthy = report(findings) && isHealthy
        if findings.isEmpty { done("\(items.count) item(s) checked, nothing to fix") }
    }
    print(isHealthy ? "\nReady." : "\nFix the ✗ items before releasing.")
    if !isHealthy { exit(1) }
}

// MARK: release

func runRelease() async throws {
    guard CommandLine.arguments.count > 2, let version = ReleaseVersion(CommandLine.arguments[2]) else {
        throw DebutError("Which version? For example: debut release 1.0.0, or debut release alpha-1.1")
    }
    let config = try loadConfig()
    let key = try requireKey()
    guard let identity = try SigningKeychain.developerIDs().first else {
        throw DebutError("No Developer ID certificate on this Mac. Run `debut setup`.")
    }
    let shouldPublish = !flag("--no-publish")
    let repository = option("--repo") ?? config.repository ?? GitHubRelease.repositoryOfCurrentFolder(workingDirectory)
    if shouldPublish {
        guard let repository else { throw DebutError("Which GitHub repo? Use --repo <owner/name>, or use --no-publish.") }
        if GitHubRelease(repository: repository).exists(tag: version.tag) {
            throw DebutError("\(repository) already has a release called \(version.tag).")
        }
    }

    if let build = option("--build") ?? config.build {
        step("Building: \(build)")
        guard try Shell.runVisible(command: build, directory: workingDirectory) == 0 else {
            throw DebutError("The build command failed.")
        }
    }

    let app = try requireApp(config)
    guard app.version == version.version else {
        throw DebutError("\(app.name) says it's version \(app.version ?? "unknown"), but you asked to release \(version.version). Update its Info.plist first.")
    }

    step("Checking \(app.url.lastPathComponent)")
    report(Doctor.examine(app.facts(), requireSignature: false))
    report(Doctor.examine(certificates: try await AppleAPI(key: key).developerIDCertificates(), now: Date()))

    step("Signing with \(identity)")
    try app.sign(identity: identity)
    done("Signed \(app.nestedCode.count + 1) item(s), inside out, with the hardened runtime")

    let assetName = ReleaseAsset.fileName(appName: app.name)
    let output = option("--output") ?? URL(fileURLWithPath: workingDirectory).appendingPathComponent(assetName).path
    step("Building the DMG")
    try DiskImageBuilder().build(app: app, output: output)
    let signed = try Shell.run("/usr/bin/codesign", ["--force", "--timestamp", "--sign", identity, output])
    guard signed.status == 0 else { throw DebutError("Couldn't sign the DMG:\n\(signed.output)") }
    done(output)

    step("Notarizing with Apple (this can take a few minutes)")
    try Notary.notarizeAndStaple(output, key: key)
    done("Apple accepted it, and the ticket is attached")

    guard shouldPublish, let repository else {
        step("Verifying the DMG")
        try DiskImage.verify(output, expectedVersion: version.version).forEach(done)
        print("\nDone: \(output) (not published)")
        return
    }

    step("Publishing to \(repository)")
    let notesFile = option("--notes") ?? "ReleaseNotes/\(version.version).md"
    let notes = ReleaseNotes(markdown: (try? String(contentsOfFile: notesFile, encoding: .utf8)) ?? "")
    if notes.body.isEmpty { print("  ! No notes found at \(notesFile), so the description will be empty.") }
    let release = GitHubRelease(repository: repository)
    let url = try release.publish(
        tag: version.tag,
        title: notes.title(appName: app.name, version: version),
        notes: notes.body,
        file: output
    )
    done(url)

    step("Downloading the published DMG and checking it as a user would")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("debut-check-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        let downloaded = try release.download(tag: version.tag, assetName: assetName, into: directory)
        try DiskImage.verify(downloaded, expectedVersion: version.version).forEach(done)
    } catch {
        throw DebutError("\(error)\n\nThis release is already live and failed its checks, so people can download it. To remove it: gh release delete \(version.tag) -R \(repository) --cleanup-tag --yes")
    }
    print("\nDone: \(url)")
}

// MARK: entry point

do {
    switch CommandLine.arguments.dropFirst().first {
    case "setup": try await runSetup()
    case "doctor": try await runDoctor()
    case "release": try await runRelease()
    case "ci-keychain": try CISigning.prepareTemporaryKeychain()
    default: print(usage)
    }
} catch {
    FileHandle.standardError.write(Data("\n✗ \(error)\n".utf8))
    exit(1)
}
