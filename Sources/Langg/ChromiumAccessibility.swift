import Foundation

/// Detect the embedded engine, including frameworks renamed by their host app.
/// Chromium's accessibility opt-in must not be applied to unrelated native apps.
enum ChromiumAccessibility {
    static func isChromiumApplication(at bundleURL: URL, fileManager: FileManager = .default) -> Bool {
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(at: frameworks,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return false }
        let knownFrameworks = ["Electron Framework.framework", "Chromium Embedded Framework.framework", "Chromium Framework.framework"]
        return entries.contains { framework in
            guard framework.pathExtension == "framework" else { return false }
            if knownFrameworks.contains(framework.lastPathComponent) { return true }
            let resources = framework.appendingPathComponent("Resources", isDirectory: true)
            return fileManager.fileExists(atPath: resources.appendingPathComponent("icudtl.dat").path)
                && ["resources.pak", "cef.pak"].contains {
                    fileManager.fileExists(atPath: resources.appendingPathComponent($0).path)
                }
        }
    }
}
