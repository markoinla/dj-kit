import AppKit
import SwiftUI

/// Entry point. `-renderPreviews <dir>` (Debug builds) draws the main screens
/// to PNGs offscreen and exits, for checking the design without a GUI
/// session; anything else starts the app.
@main
@MainActor
enum DJToolsMain {
    static func main() {
        #if DEBUG
        if let directory = LaunchArguments.value("renderPreviews") {
            DJFont.register()
            PreviewRenderer.run(into: URL(filePath: directory, directoryHint: .isDirectory))
            exit(0)
        }
        #endif
        DJToolsApp.main()
    }
}

struct DJToolsApp: App {
    @State private var model: AppModel

    init() {
        DJFont.register()
        // Tooltips after 0.4 s, as in Wax Studio.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 400])
        let engines = Engines.forLaunch(supportDirectory: AppPaths.support)
        _model = State(initialValue: AppModel(engines: engines, settings: AppSettings(), store: LibraryStore()))
    }

    var body: some Scene {
        WindowGroup("DJ Tools") {
            MainView()
                .environment(model)
                .frame(minWidth: 880, minHeight: 560)
                .tint(DJColor.ring)
                .windowBackground(DJColor.background)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environment(model)
                .tint(DJColor.ring)
        }
    }
}
