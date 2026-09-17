import Foundation
import AppKit
import AVFoundation

@MainActor enum Diagnostics {
    static func run() {
        let resources = Bundle.main.resourceURL!
        let result: [String: Any] = [
            "bundle": Bundle.main.bundleIdentifier ?? "",
            "name": Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "path": Bundle.main.bundleURL.path,
            "native": true,
            "accessibility": AXIsProcessTrusted(),
            "microphone": AVCaptureDevice.authorizationStatus(for: .audio).rawValue,
            "runtime": FileManager.default.isExecutableFile(atPath: resources.appendingPathComponent("runtime/node").path),
            "backend": FileManager.default.fileExists(atPath: resources.appendingPathComponent("backend/service.mjs").path),
            "sentences": DocumentParser.sentences("# Summary\n\nOne sentence. Another sentence.").count
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), let json = String(data: data, encoding: .utf8) { print(json) }
    }
}
