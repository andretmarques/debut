import AppKit
import DebutCore
import Foundation

/// Reads the facts about an app on disk, and signs it.
public struct AppBundle {
    private static let timestampRetries = 3
    private static let timestampRetryDelay: TimeInterval = 5

    public let url: URL

    public init(path: String) throws {
        url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension == "app", FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path) else {
            throw DebutError("\(path) isn't an app.")
        }
    }

    private var info: [String: Any] { Self.info(of: url) }

    private static func info(of bundle: URL) -> [String: Any] {
        NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
    }

    public var name: String { url.deletingPathExtension().lastPathComponent }
    public var version: String? { info["CFBundleShortVersionString"] as? String }

    public var iconFile: URL? { Self.iconFile(of: url) }

    private static func iconFile(of bundle: URL) -> URL? {
        guard var name = info(of: bundle)["CFBundleIconFile"] as? String else { return nil }
        if !name.hasSuffix(".icns") { name += ".icns" }
        let file = bundle.appendingPathComponent("Contents/Resources/\(name)")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Libraries and nested apps, deepest first, because a bundle's signature covers what's inside it.
    public var nestedCode: [URL] {
        let contents = url.appendingPathComponent("Contents")
        guard let walker = FileManager.default.enumerator(at: contents, includingPropertiesForKeys: nil) else { return [] }
        var found: [URL] = []
        for case let item as URL in walker where ["app", "appex", "xpc", "framework", "dylib", "bundle"].contains(item.pathExtension) {
            found.append(item)
        }
        return found.sorted { $0.pathComponents.count > $1.pathComponents.count }
    }

    public func facts() -> [CodeFacts] {
        var items = [CodeFacts(name: name, kind: .app, signature: Self.signature(of: url), icon: Self.icon(of: url))]
        for item in nestedCode.reversed() {
            let isApp = item.pathExtension == "app"
            items.append(CodeFacts(
                name: item.lastPathComponent,
                kind: isApp ? .nestedApp : .library,
                signature: Self.signature(of: item),
                icon: isApp ? Self.icon(of: item) : nil
            ))
        }
        return items
    }

    private static func signature(of code: URL) -> SignatureFacts? {
        guard let details = try? Shell.run("/usr/bin/codesign", ["-dv", "--verbose=2", code.path]), details.status == 0 else {
            return nil
        }
        let team = details.output.components(separatedBy: .newlines)
            .first { $0.hasPrefix("TeamIdentifier=") }?
            .replacingOccurrences(of: "TeamIdentifier=", with: "")
        let check = try? Shell.run("/usr/bin/codesign", ["--verify", "--strict", code.path])
        return SignatureFacts(
            isValid: check?.status == 0,
            hasHardenedRuntime: details.output.contains("(runtime)"),
            isAdHoc: details.output.contains("Signature=adhoc"),
            teamIdentifier: team == "not set" ? nil : team
        )
    }

    private static func icon(of bundle: URL) -> IconFacts? {
        iconFile(of: bundle).flatMap(IconShape.facts(of:))
    }

    /// Signing needs Apple's timestamp server, which fails now and then.
    private func signRetryingTimestamps(_ code: URL, identity: String) throws {
        // A library's temporary build signature gets an identifier with a hash in it, which changes
        // with each build. Only bundles have an identifier worth keeping.
        let preserved = code.pathExtension == "dylib" ? "entitlements" : "entitlements,identifier"
        let arguments = [
            "--force", "--timestamp", "--options", "runtime",
            "--preserve-metadata=\(preserved)",
            "--sign", identity, code.path,
        ]
        var result = try Shell.run("/usr/bin/codesign", arguments)
        for _ in 0..<Self.timestampRetries where result.status != 0 && result.output.contains("timestamp") {
            Thread.sleep(forTimeInterval: Self.timestampRetryDelay)
            result = try Shell.run("/usr/bin/codesign", arguments)
        }
        guard result.status == 0 else { throw DebutError("Couldn't sign \(code.lastPathComponent):\n\(result.output)") }
    }

    /// Inside out, so each bundle's signature covers the signed code within it.
    public func sign(identity: String) throws {
        for code in nestedCode + [url] {
            try signRetryingTimestamps(code, identity: identity)
        }
        let check = try Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", url.path])
        guard check.status == 0 else { throw DebutError("The signature didn't verify:\n\(check.output)") }
    }
}

/// Compares an icon's outline with Apple's rounded square: 824 of 1024 pixels, corner radius about 185.
enum IconShape {
    private static let side = 256

    static func facts(of file: URL) -> IconFacts? {
        guard let image = NSImage(contentsOf: file), let alpha = alphaPixels(of: image) else { return nil }
        let mask = expectedMask()
        var different = 0
        for index in alpha.indices where (alpha[index] > 127) != (mask[index] > 127) {
            different += 1
        }
        return IconFacts(shapeMismatch: Double(different) / Double(alpha.count))
    }

    private static func context() -> CGContext? {
        CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
    }

    private static func pixels(of context: CGContext) -> [UInt8]? {
        guard let data = context.data else { return nil }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: side * side))
    }

    private static func alphaPixels(of image: NSImage) -> [UInt8]? {
        guard let context = context(), let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        context.interpolationQuality = .high
        context.draw(picture, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixels(of: context)
    }

    private static func expectedMask() -> [UInt8] {
        guard let context = context() else { return [] }
        let scale = Double(side) / 1024
        let edge = 824 * scale
        let inset = (Double(side) - edge) / 2
        context.addPath(CGPath(
            roundedRect: CGRect(x: inset, y: inset, width: edge, height: edge),
            cornerWidth: 185.4 * scale, cornerHeight: 185.4 * scale, transform: nil
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fillPath()
        return pixels(of: context) ?? []
    }
}
