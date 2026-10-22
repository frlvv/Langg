import AppKit
import Combine
import Sparkle

/// One Sparkle lifetime for the menu, settings and scheduled native update alerts.
@MainActor final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticChecks = false
    @Published private(set) var isStarted = false
    @Published private(set) var configurationMessage: String?

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: false,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticChecks)
    }

    func start() {
        guard !isStarted else { return }
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app",
              let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: publicKey)?.count == 32,
              bundle.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool == true else {
            configurationMessage = "Проверка обновлений доступна в установленной версии Langg."
            return
        }
        // Sparkle owns the schedule, preferences, archive verification and installer.
        // Defaults live in Info.plist; never overwrite the user's update preferences here.
        controller.startUpdater()
        isStarted = true
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        guard isStarted else { return }
        controller.updater.automaticallyChecksForUpdates = enabled
    }
}
