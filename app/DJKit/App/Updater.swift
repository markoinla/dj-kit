import Foundation
import Observation
import Sparkle
import SwiftUI

/// Sparkle 2 auto-updates for the notarized DMG build (`scripts/release.sh`).
/// Feed and public key come from Info.plist (`SUFeedURL`, `SUPublicEDKey`,
/// set in project.yml). The feed is the latest GitHub release's appcast.xml.
///
/// Off in Debug builds and under XCTest, so dev builds don't hit the feed or
/// show Sparkle alerts. Headless runs never touch `shared`.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    private(set) var canCheckForUpdates = false
    /// The newer version the feed offers ("0.2.0"), from a quiet check at
    /// launch. Drives the sidebar's update card.
    private(set) var availableVersion: String?
    /// Closed from the sidebar; the next launch brings it back.
    var isUpdateCardDismissed = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private let delegate = UpdaterDelegate()
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init(bundle: Bundle = .main) {
        let enabled = Self.isEnabled(bundle: bundle)
        controller = SPUStandardUpdaterController(
            startingUpdater: enabled,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        #if DEBUG
        // `-uiPreviewUpdate 0.2.0` shows the sidebar card without a real check.
        if let version = UserDefaults.standard.string(forKey: "uiPreviewUpdate") {
            availableVersion = version
            return
        }
        #endif
        guard enabled else { return }
        delegate.onResult = { [weak self] version in self?.availableVersion = version }
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshCanCheck() }
        }
        // Asks the feed without any Sparkle UI; the answer lands in `availableVersion`.
        controller.updater.checkForUpdateInformation()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    private func refreshCanCheck() {
        canCheckForUpdates = controller.updater.canCheckForUpdates
    }

    nonisolated static func isEnabled(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        #if DEBUG
        return false
        #else
        if environment["XCTestConfigurationFilePath"] != nil { return false }
        guard let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else { return false }
        return !key.isEmpty
        #endif
    }
}

/// Sparkle's answer to any check, quiet or not: the version on offer, or nil.
@MainActor
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var onResult: ((String?) -> Void)?

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        onResult?(item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        onResult?(nil)
    }
}

/// "Check for Updates…" under the app menu's About item.
struct CheckForUpdatesButton: View {
    var updater: Updater = .shared

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

/// At the foot of the sidebar when the launch check finds a newer version.
struct UpdateAvailableCard: View {
    var updater: Updater = .shared

    var body: some View {
        if let version = updater.availableVersion, !updater.isUpdateCardDismissed {
            HStack(alignment: .top, spacing: DJSpace.sm) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(DJColor.flame)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DJSpace.xxs) {
                    Text("Update available")
                        .djText(.bodyMedium)
                        .foregroundStyle(DJColor.foreground)
                    Text("DJ Kit \(version)")
                        .djText(.caption)
                        .foregroundStyle(DJColor.mutedForeground)
                    Button("Update…") { updater.checkForUpdates() }
                        .buttonStyle(.borderless)
                        .font(.dj(11, weight: 600))
                        .foregroundStyle(DJColor.ring)
                        .disabled(!updater.canCheckForUpdates)
                        .padding(.top, DJSpace.xxs)
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { updater.isUpdateCardDismissed = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DJColor.mutedForeground)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide until next launch")
                .accessibilityLabel("Close")
            }
            .padding(DJSpace.md)
            .background(DJColor.background, in: RoundedRectangle(cornerRadius: DJRadius.lg))
            .overlay(RoundedRectangle(cornerRadius: DJRadius.lg).strokeBorder(DJColor.border))
            .padding(DJSpace.md)
            .background(DJColor.sidebar)
            .transition(.opacity)
        }
    }
}
