import AppKit
import DebutCore
import Foundation

/// Builds the designed DMG window.
public struct DiskImageBuilder {
    private static let window = CGSize(width: 640, height: 400)
    private static let dmgbuildPackages = ["dmgbuild==1.6.5", "ds_store==1.3.1", "mac_alias==2.2.2"]

    public init() {}

    public func build(app: AppBundle, output: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("debut-dmg-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let background = directory.appendingPathComponent("background.tiff")
        try DiskImageArt.write(appName: app.name, size: Self.window, to: background, working: directory)

        let settings = directory.appendingPathComponent("settings.py")
        try settingsFile(app: app, background: background).write(to: settings, atomically: true, encoding: .utf8)

        try? FileManager.default.removeItem(atPath: output)
        let tool = try installTools()
        let result = try Shell.run(tool, ["-s", settings.path, app.name, output])
        guard result.status == 0 else { throw DebutError("Couldn't build the DMG:\n\(result.output)") }
    }

    private func settingsFile(app: AppBundle, background: URL) -> String {
        let fileName = app.url.lastPathComponent
        var lines = [
            "format = \"UDZO\"",
            "files = [\(PythonLiteral.string(app.url.path))]",
            "symlinks = {\"Applications\": \"/Applications\"}",
            "background = \(PythonLiteral.string(background.path))",
            "window_rect = ((200, 200), (\(Int(Self.window.width)), \(Int(Self.window.height))))",
            "default_view = \"icon-view\"",
            "show_status_bar = False",
            "show_tab_view = False",
            "show_toolbar = False",
            "show_pathbar = False",
            "show_sidebar = False",
            "icon_size = 128",
            "text_size = 14",
            "icon_locations = {\(PythonLiteral.string(fileName)): (170, 200), \"Applications\": (470, 200)}",
        ]
        if let icon = app.iconFile {
            lines.append("icon = \(PythonLiteral.string(icon.path))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func installTools() throws -> String {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let environment = caches.appendingPathComponent("Debut/dmg-tools")
        let tool = environment.appendingPathComponent("bin/dmgbuild").path
        if FileManager.default.isExecutableFile(atPath: tool) { return tool }

        try FileManager.default.createDirectory(at: environment.deletingLastPathComponent(), withIntermediateDirectories: true)
        let create = try Shell.run("/usr/bin/env", ["python3", "-m", "venv", environment.path])
        guard create.status == 0 else { throw DebutError("Debut needs Python 3 to build DMGs:\n\(create.output)") }
        let pip = environment.appendingPathComponent("bin/pip").path
        let install = try Shell.run(pip, ["install", "--quiet", "--disable-pip-version-check"] + Self.dmgbuildPackages)
        guard install.status == 0 else { throw DebutError("Couldn't install dmgbuild:\n\(install.output)") }
        return tool
    }
}

/// Finder's icon labels are black or white depending on the viewer's light or dark mode, and a DMG can't
/// choose. The blue stays in the mid-tones so both stay readable on it.
enum DiskImageArt {
    static func write(appName: String, size: CGSize, to output: URL, working: URL) throws {
        let standard = working.appendingPathComponent("background.png")
        let retina = working.appendingPathComponent("background@2x.png")
        try render(appName: appName, size: size, scale: 1).write(to: standard)
        try render(appName: appName, size: size, scale: 2).write(to: retina)
        let result = try Shell.run("/usr/bin/tiffutil", ["-cathidpicheck", standard.path, retina.path, "-out", output.path])
        guard result.status == 0 else { throw DebutError("Couldn't make the DMG background:\n\(result.output)") }
    }

    private static func render(appName: String, size: CGSize, scale: Int) -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        drawBackground(size)
        drawArrow()
        drawTitle("Drag \(appName) to Applications", size)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])!
    }

    private static func drawBackground(_ size: CGSize) {
        let rect = NSRect(origin: .zero, size: size)
        NSGradient(
            starting: NSColor(srgbRed: 0.27, green: 0.42, blue: 0.82, alpha: 1),
            ending: NSColor(srgbRed: 0.37, green: 0.54, blue: 0.93, alpha: 1)
        )!.draw(in: rect, angle: 90)
        NSGradient(starting: NSColor(white: 1, alpha: 0.14), ending: NSColor(white: 1, alpha: 0))!
            .draw(in: rect, relativeCenterPosition: NSPoint(x: 0, y: 0.5))
    }

    private static func drawArrow() {
        let curve = NSBezierPath()
        curve.move(to: NSPoint(x: 248, y: 188))
        curve.curve(to: NSPoint(x: 322, y: 232), controlPoint1: NSPoint(x: 284, y: 188), controlPoint2: NSPoint(x: 288, y: 232))
        curve.curve(to: NSPoint(x: 392, y: 212), controlPoint1: NSPoint(x: 352, y: 232), controlPoint2: NSPoint(x: 362, y: 212))
        let head = NSBezierPath()
        head.move(to: NSPoint(x: 376, y: 232))
        head.line(to: NSPoint(x: 396, y: 212))
        head.line(to: NSPoint(x: 376, y: 192))
        let glow = NSShadow()
        glow.shadowColor = NSColor(srgbRed: 0.1, green: 0.18, blue: 0.5, alpha: 0.45)
        glow.shadowBlurRadius = 10
        glow.shadowOffset = NSSize(width: 0, height: -2)
        glow.set()
        NSColor.white.setStroke()
        for path in [curve, head] {
            path.lineWidth = 7
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
        NSShadow().set()
    }

    private static func drawTitle(_ title: String, _ size: CGSize) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]).draw(in: NSRect(x: 0, y: size.height - 76, width: size.width, height: 34))
    }
}

public enum DiskImage {
    /// Checks a DMG the way a person's Mac will: Gatekeeper, Apple's ticket, then the app inside.
    public static func verify(_ file: String, expectedVersion: String?) throws -> [String] {
        var passed: [String] = []
        let open = try Shell.run("/usr/sbin/spctl", ["-a", "-vv", "-t", "open", "--context", "context:primary-signature", file])
        guard open.output.contains("source=Notarized Developer ID") else { throw DebutError("macOS doesn't accept the DMG:\n\(open.output)") }
        passed.append("macOS accepts the DMG as Notarized Developer ID")
        guard try Shell.run("/usr/bin/xcrun", ["stapler", "validate", file]).status == 0 else { throw DebutError("The DMG has no Apple ticket attached.") }
        passed.append("Apple's ticket is attached")

        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("debut-mount-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = try Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, file])
        guard attach.status == 0 else { throw DebutError("Couldn't open the DMG:\n\(attach.output)") }
        defer {
            _ = try? Shell.run("/usr/bin/hdiutil", ["detach", mount.path])
            try? FileManager.default.removeItem(at: mount)
        }

        let names = (try? FileManager.default.contentsOfDirectory(atPath: mount.path)) ?? []
        guard let appName = names.first(where: { $0.hasSuffix(".app") }) else { throw DebutError("There's no app in the DMG.") }
        let app = try AppBundle(path: mount.appendingPathComponent(appName).path)
        let exec = try Shell.run("/usr/sbin/spctl", ["-a", "-vv", "-t", "exec", app.url.path])
        guard exec.output.contains("source=Notarized Developer ID") else { throw DebutError("macOS doesn't accept the app:\n\(exec.output)") }
        passed.append("macOS accepts \(appName) as Notarized Developer ID")
        if let expectedVersion, app.version != expectedVersion {
            throw DebutError("The DMG contains version \(app.version ?? "unknown"), not \(expectedVersion).")
        }
        passed.append("It contains version \(app.version ?? "unknown")")
        guard FileManager.default.fileExists(atPath: mount.appendingPathComponent("Applications").path) else {
            throw DebutError("The DMG has no Applications shortcut.")
        }
        passed.append("The Applications shortcut is there")
        return passed
    }
}

public struct GitHubRelease {
    fileprivate static let gh: String = {
        let result = try? Shell.run("/bin/zsh", ["-lc", "command -v gh"])
        return result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "gh"
    }()

    private let repository: String

    public init(repository: String) {
        self.repository = repository
    }

    public static func repositoryOfCurrentFolder(_ directory: String) -> String? {
        guard let result = try? Shell.run(gh, ["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"], directory: directory),
              result.status == 0 else { return nil }
        let name = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    public func exists(tag: String) -> Bool {
        (try? Shell.run(Self.gh, ["release", "view", tag, "-R", repository, "--json", "tagName"]))?.status == 0
    }

    public func publish(tag: String, title: String, notes: String, file: String) throws -> String {
        let notesFile = FileManager.default.temporaryDirectory.appendingPathComponent("debut-notes-" + UUID().uuidString)
        try notes.write(to: notesFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: notesFile) }
        let result = try Shell.run(Self.gh, ["release", "create", tag, file, "-R", repository, "--title", title, "--notes-file", notesFile.path])
        guard result.status == 0 else { throw DebutError("GitHub didn't accept the release:\n\(result.output)") }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).last ?? ""
    }

    /// Downloads what was really published, so the checks run on what users will get.
    public func download(tag: String, assetName: String, into directory: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try Shell.run(Self.gh, ["release", "download", tag, "-R", repository, "-p", assetName, "-D", directory.path, "--clobber"])
        guard result.status == 0 else { throw DebutError("Couldn't download the published DMG:\n\(result.output)") }
        return directory.appendingPathComponent(assetName).path
    }
}

public enum GitHubSecrets {
    /// The value goes through standard input, never as an argument, where other processes could see it.
    public static func set(_ name: String, to value: String, repository: String) throws {
        let result = try Shell.run(GitHubRelease.gh, ["secret", "set", name, "-R", repository], input: Data(value.utf8))
        guard result.status == 0 else { throw DebutError("GitHub refused \(name). Check that `gh` is logged in with access to \(repository).") }
    }
}
