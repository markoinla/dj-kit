import AppKit
import AudioExport
import SwiftUI

/// Settings (⌘,): a sidebar of sections (results, Track ID, analysis,
/// repair, loudness, credits) and the selected section's form.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("settingsSection") private var section: SettingsSection = .general
    @State private var isConfirmingReset = false
    @State private var isResetting = false
    @State private var isConfirmingModelRemoval = false
    @State private var isRemovingModel = false

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: Binding(get: { section }, set: { if let new = $0 { section = new } })) { item in
                Label(item.title, systemImage: item.systemImage).tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Form { detail }
                .formStyle(.grouped)
                .navigationTitle(section.title)
        }
        .frame(width: 720, height: 500)
        .confirmationDialog("Remove the repair model?", isPresented: $isConfirmingReset) {
            Button("Remove", role: .destructive) {
                isResetting = true
                Task {
                    await model.resetApollo()
                    isResetting = false
                }
            }
        } message: {
            Text("Running repairs stop. The next one downloads 66 MB again.")
        }
        .confirmationDialog("Remove the tempo model?", isPresented: $isConfirmingModelRemoval) {
            Button("Remove", role: .destructive) {
                isRemovingModel = true
                Task {
                    await model.removeAnalysisModel()
                    isRemovingModel = false
                }
            }
        } message: {
            Text("The next analysis downloads 81 MB again.")
        }
        .task {
            await model.refreshApolloState()
            await model.refreshAnalysisModel()
        }
    }

    @ViewBuilder private var detail: some View {
        @Bindable var settings = model.settings
        switch section {
        case .general:
            Section {
                LabeledContent("Output folder") {
                    HStack(spacing: DJSpace.sm) {
                        Text(DJFormat.path(settings.outputFolder))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { chooseFolder(settings) }
                    }
                }
                HStack {
                    Button("Show in Finder") { revealOutputFolder(settings.outputFolder) }
                    if !settings.isDefaultOutputFolder {
                        Button("Use Default") { settings.outputFolder = AppPaths.defaultOutputFolder }
                    }
                }
                FormatPicker(title: "Save as", selection: $settings.lastRecipe.format)
            } footer: {
                Text("“Artist - Title.\(settings.lastRecipe.format.fileExtension)”, stems in “Artist - Title (Stems)”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.engines.isFake {
                Section("Engines") {
                    Text("Demo engines (-useFakeEngines)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case .trackID:
            Section {
                Toggle("Identify tracks when added", isOn: $settings.identifyOnAdd)
                Toggle("Rename files on Apply", isOn: $settings.renameOnApply)
                Toggle("Apply sure matches automatically", isOn: $settings.autoApplyMatches)
            } footer: {
                Text("Shazam + Apple Music. Apply writes the tags without re-encoding.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .analysis:
            Section {
                Toggle("Detect BPM and key", isOn: $settings.detectBPMKey)
                    .onChange(of: settings.detectBPMKey) { _, on in if !on { model.dropQueuedAnalyses() } }
                Picker("Key tag", selection: $settings.keyTag) {
                    ForEach(KeyTagStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                LabeledContent("Model", value: isRemovingModel ? "Removing…" : model.analysisModelReady ? "Installed" : "Not installed")
                Button("Remove Model…", role: .destructive) { isConfirmingModelRemoval = true }
                    .disabled(isRemovingModel || !model.analysisModelReady)
            } footer: {
                Text("Only fills BPM and key tags a file doesn't have.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .apollo:
            Section {
                LabeledContent("Model", value: apolloStatus)
                Button("Remove Repair Model…", role: .destructive) { isConfirmingReset = true }
                    .disabled(isResetting || model.apolloState == .notInstalled || model.apolloState.isInstalling)
            }

        case .loudness:
            Section {
                Picker("Target", selection: $settings.targetLUFS) {
                    ForEach(AppSettings.targetChoices, id: \.self) { lufs in
                        Text(lufs == AppSettings.defaultTargetLUFS ? "\(DJFormat.lufs(lufs, decimals: 0)) (default)" : DJFormat.lufs(lufs, decimals: 0))
                            .tag(lufs)
                    }
                }
                Picker("True-peak ceiling", selection: $settings.ceilingDBTP) {
                    ForEach(AppSettings.ceilingChoices, id: \.self) { dBTP in
                        Text(dBTP == AppSettings.defaultCeilingDBTP ? "\(DJFormat.dBTP(dBTP)) (default)" : DJFormat.dBTP(dBTP))
                            .tag(dBTP)
                    }
                }
            } footer: {
                Text("Gain only, no limiter. Stops at the ceiling.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .credits:
            Section {
                ForEach(Credits.all) { credit in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Link(credit.name, destination: credit.url)
                            Spacer()
                            Text(credit.license).foregroundStyle(.secondary)
                        }
                        Text(credit.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// A file-type picker: lossless first, then the MP3 bitrates.
    private struct FormatPicker: View {
        let title: String
        @Binding var selection: AudioFileFormat

        var body: some View {
            Picker(title, selection: $selection) {
                Section("Lossless") {
                    ForEach(AudioFileFormat.allCases.filter(\.isLossless)) { format in
                        Text(format.title).tag(format)
                    }
                }
                Section("Lossy") {
                    ForEach(AudioFileFormat.allCases.filter { !$0.isLossless }) { Text($0.title).tag($0) }
                }
            }
        }
    }

    private var apolloStatus: String {
        if isResetting { return "Removing…" }
        switch model.apolloState {
        case .notInstalled: return "Not installed"
        case .installing(let line): return line
        case .ready: return "Installed"
        case .failed(let message): return "Setup failed: \(message)"
        }
    }

    private func chooseFolder(_ settings: AppSettings) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.outputFolder
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            settings.outputFolder = url
        }
    }

    private func revealOutputFolder(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

/// The settings window's sidebar entries.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, trackID, analysis, apollo, loudness, credits

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .trackID: "Track ID"
        case .analysis: "Analysis"
        case .apollo: "Repair"
        case .loudness: "Loudness"
        case .credits: "Credits"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "folder"
        case .trackID: "shazam.logo"
        case .analysis: "metronome"
        case .apollo: "wand.and.stars"
        case .loudness: "speaker.wave.2"
        case .credits: "heart"
        }
    }
}
