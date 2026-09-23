import Combine
import Foundation
import Sparkle

/// Sparkle's standard updater, wrapped so SwiftUI can bind to it. Feed URL
/// and EdDSA public key come from Info.plist (`SUFeedURL`/`SUPublicEDKey`,
/// set in project.yml).
@MainActor
final class AppUpdater: ObservableObject {
    private let controller: SPUStandardUpdaterController
    private var updater: SPUUpdater { controller.updater }

    @Published private(set) var canCheckForUpdates = false

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyDownloadsUpdates = newValue
        }
    }

    var lastUpdateCheckDate: Date? { updater.lastUpdateCheckDate }

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
