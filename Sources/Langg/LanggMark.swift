import AppKit
import SwiftUI

@MainActor enum LanggMark {
    static let iconImage = loadImage(named: "Icon")
    static let menuImage: NSImage = {
        let image = loadImage(named: "Mark")
        image.size = NSSize(width: 18 * 56.43115234375 / 57, height: 18)
        image.isTemplate = true
        return image
    }()

    private static func loadImage(named name: String) -> NSImage {
        guard let url = Bundle.main.url(forResource: name, withExtension: "pdf", subdirectory: "Brand"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(size: NSSize(width: 100, height: 100))
        }
        image.accessibilityDescription = "Langg"
        return image
    }
}

struct LanggAboutMark: View {
    var body: some View {
        Image(nsImage: LanggMark.iconImage)
            .resizable()
            .scaledToFit()
            .frame(width: 88, height: 88)
            .accessibilityLabel("Langg")
    }
}
