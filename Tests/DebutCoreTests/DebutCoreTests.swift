import Foundation
import Testing
@testable import DebutCore

@Suite struct ReleaseTests {
    @Test func versionsBecomeTags() {
        #expect(ReleaseVersion("1.2.3")?.tag == "v1.2.3")
        #expect(ReleaseVersion("alpha-1.1")?.tag == "alpha-1.1")
        #expect(ReleaseVersion("beta-2")?.tag == "beta-2")
    }

    @Test func oddVersionsAreRefused() {
        for text in ["", "1.2", "v1.2.3", "alpha", "1.2.3; rm -rf", "alpha-1.1\nx"] {
            #expect(ReleaseVersion(text) == nil)
        }
    }

    @Test func notesNameTheRelease() {
        let notes = ReleaseNotes(markdown: "# Clean Edge\n\nBetter icon.\n")
        #expect(notes.codename == "Clean Edge")
        #expect(notes.body == "Better icon.")
        #expect(notes.title(appName: "Kinetic", version: ReleaseVersion("alpha-1.1")!) == "Kinetic alpha-1.1 · Clean Edge")
    }

    @Test func notesWithoutACodenameStillWork() {
        let notes = ReleaseNotes(markdown: "Just text.")
        #expect(notes.codename == nil)
        #expect(notes.title(appName: "App", version: ReleaseVersion("1.0.0")!) == "App 1.0.0")
    }
}

@Suite struct ReleaseAssetTests {
    @Test func namesSurviveGitHub() {
        #expect(ReleaseAsset.fileName(appName: "Kinetic") == "Kinetic.dmg")
        #expect(ReleaseAsset.fileName(appName: "Debut Test") == "Debut-Test.dmg")
    }
}

@Suite struct PythonLiteralTests {
    @Test func pathsStayIntact() {
        #expect(PythonLiteral.string("/tmp/Debut Test.app") == "\"/tmp/Debut Test.app\"")
        #expect(PythonLiteral.string("/Apps/André's.app") == "\"/Apps/André's.app\"")
    }

    @Test func quotesAndBackslashesCantBreakOut() {
        #expect(PythonLiteral.string("a\"b") == "\"a\\\"b\"")
        #expect(PythonLiteral.string("a\\b") == "\"a\\\\b\"")
        #expect(PythonLiteral.string("a\nb") == "\"a\\nb\"")
    }
}

@Suite struct CredentialTests {
    @Test func keyIDComesFromTheFileName() {
        #expect(Credentials.keyID(fromFileName: "AuthKey_ABC123DEF4.p8") == "ABC123DEF4")
        #expect(Credentials.keyID(fromFileName: "key.p8") == nil)
        #expect(Credentials.keyID(fromFileName: "AuthKey_abc.p8") == nil)
    }

    @Test func aKeyIDIsNotAnIssuerID() {
        #expect(!Credentials.isIssuerID("ABC123DEF4"))
        #expect(Credentials.isIssuerID("00000000-0000-0000-0000-000000000000"))
    }

    @Test func onlyDeveloperIDIdentitiesCount() {
        let output = """
          1) ABC "Apple Development: A (X)"
          2) DEF "Developer ID Application: A (TEAM123456)"
             2 valid identities found
        """
        #expect(SigningIdentities.developerIDs(inFindIdentityOutput: output) == ["Developer ID Application: A (TEAM123456)"])
    }
}

@Suite struct DoctorTests {
    private let good = SignatureFacts(isValid: true, hasHardenedRuntime: true, isAdHoc: false, teamIdentifier: "T")
    private let goodIcon = IconFacts(shapeMismatch: 0.005)

    @Test func aHealthyAppHasNoFindings() {
        let items = [
            CodeFacts(name: "App", kind: .app, signature: good, icon: goodIcon),
            CodeFacts(name: "lib.dylib", kind: .library, signature: good),
        ]
        #expect(Doctor.examine(items, requireSignature: true).isEmpty)
    }

    @Test func aNestedAppWithoutAnIconIsFlagged() {
        let items = [CodeFacts(name: "Agent", kind: .nestedApp, signature: good, icon: nil)]
        #expect(Doctor.examine(items, requireSignature: true).first?.message.contains("no icon") == true)
    }

    @Test func librariesDontNeedIcons() {
        let items = [CodeFacts(name: "lib", kind: .library, signature: good)]
        #expect(Doctor.examine(items, requireSignature: true).isEmpty)
    }

    @Test func anOffGridIconIsFlagged() {
        let items = [CodeFacts(name: "App", kind: .app, signature: good, icon: IconFacts(shapeMismatch: 0.09))]
        #expect(Doctor.examine(items, requireSignature: true).first?.message.contains("grey plate") == true)
    }

    @Test func adHocAndMissingSignaturesAreProblems() {
        let adHoc = SignatureFacts(isValid: true, hasHardenedRuntime: false, isAdHoc: true, teamIdentifier: nil)
        for signature in [adHoc, nil] {
            let findings = Doctor.examine([CodeFacts(name: "App", kind: .app, signature: signature, icon: goodIcon)], requireSignature: true)
            #expect(findings.count == 1 && findings[0].severity == .problem)
        }
    }

    @Test func unsignedIsFineBeforeARelease() {
        let items = [CodeFacts(name: "App", kind: .app, signature: nil, icon: goodIcon)]
        #expect(Doctor.examine(items, requireSignature: false).isEmpty)
    }

    @Test func aMissingHardenedRuntimeIsAProblem() {
        let signature = SignatureFacts(isValid: true, hasHardenedRuntime: false, isAdHoc: false, teamIdentifier: "T")
        let findings = Doctor.examine([CodeFacts(name: "App", kind: .app, signature: signature, icon: goodIcon)], requireSignature: true)
        #expect(findings.first?.message.contains("hardened runtime") == true)
    }

    @Test func mixedTeamsAreAProblem() {
        var other = good
        other.teamIdentifier = "Z"
        let items = [
            CodeFacts(name: "App", kind: .app, signature: good, icon: goodIcon),
            CodeFacts(name: "lib", kind: .library, signature: other),
        ]
        #expect(Doctor.examine(items, requireSignature: true).first?.message.contains("different teams") == true)
    }

    @Test func certificateExpiry() {
        let now = Date(timeIntervalSince1970: 0)
        func certificate(days: Double) -> CertificateFacts {
            CertificateFacts(name: "C", expires: now.addingTimeInterval(days * 86_400))
        }
        #expect(Doctor.examine(certificates: [certificate(days: 400)], now: now).isEmpty)
        #expect(Doctor.examine(certificates: [certificate(days: 30)], now: now).first?.severity == .warning)
        #expect(Doctor.examine(certificates: [certificate(days: -1)], now: now).first?.severity == .problem)
        #expect(Doctor.examine(certificates: [], now: now).first?.severity == .problem)
        #expect(Doctor.examine(certificates: [certificate(days: -1), certificate(days: 400)], now: now).isEmpty)
    }
}
