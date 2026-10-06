import AppKit
import SwiftUI

/// Entry point. `-renderPreviews <dir>` (Debug builds) draws the main screens
/// to PNGs offscreen and exits, for checking the design without a GUI
/// session; `-selfTest <audio> <out dir>` (any build) runs the real engines
/// headlessly and prints JSON (see `SelfTest`); anything else starts the app.
@main
@MainActor
enum DJToolsMain {
    static func main() {
        // Before anything touches MLX (StemsKit included): plain fp32 matmuls,
        // not TF32. ApolloMLX's parity with PyTorch was verified this way, and
        // Apollo's per-band normalisation amplifies TF32's rounding.
        setenv("MLX_ENABLE_TF32", "0", 1)
        #if DEBUG
        if let directory = LaunchArguments.value("renderPreviews") {
            DJFont.register()
            PreviewRenderer.run(into: URL(filePath: directory, directoryHint: .isDirectory))
            exit(0)
        }
        #endif
        if SelfTest.requested() {
            SelfTest.start()
            // A run loop on the real main thread, not dispatchMain(): that
            // parks the main thread and drains the main queue on a worker,
            // so "delivered on the main thread" couldn't be checked.
            while true { RunLoop.main.run() }
        }
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
            CommandGroup(replacing: .appInfo) {
                Button("About DJ Tools") { Credits.showAboutPanel() }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .tint(DJColor.ring)
        }
    }
}
