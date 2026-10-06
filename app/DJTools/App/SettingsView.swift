import AppKit
import AudioExport
import SwiftUI

/// Settings (⌘,): a sidebar of sections (results, stems, Apollo, loudness,
/// credits) and the selected section's form.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("settingsSection") private var section: SettingsSection = .general
    @State private var isConfirmingReset = false
    @State private var isResetting = false

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
            Text("Running repairs stop, and the next one downloads about 66 MB again.")
        }
        .task { await model.refreshApolloState() }
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
                FormatPicker(title: "Save files as", selection: $settings.saveFormat)
            } header: {
                Text("Results")
            } footer: {
                Text("Stems go in a “(Stems)” folder per track; Repair writes “<track> (Repaired).\(settings.repairFormat.fileExtension)” and Normalize “<track> (Normalized).\(settings.normalizeFormat.fileExtension)”. Names start from “Artist - Title” once Track ID knows them. AIFF, FLAC and MP3 carry the tags and artwork. “Save files as” sets every tool's file type; each can still be changed in its own section.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.engines.isFake {
                Section("Engines") {
                    Text("Demo engines: jobs sleep and write placeholder files. Launched with -useFakeEngines, or the engine packages aren't linked yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case .trackID:
            Section {
                Toggle("Identify tracks when they're added", isOn: $settings.identifyOnAdd)
                Toggle("Rename files when applying", isOn: $settings.renameOnApply)
                Toggle("Apply sure matches automatically", isOn: $settings.autoApplyMatches)
            } footer: {
                Text("Track ID listens to three short bits of each track with Shazam (only fingerprints leave this Mac) and fills in the rest from Apple Music. Apply writes title, artist, album, label, year, genre, ISRC and artwork into the file without re-encoding it, and keeps tags like BPM and key. Renaming makes it “Artist - Title”. A sure match is one at least two listens agree on, with a length that fits the file. Apply before importing into Rekordbox: it finds tracks by where they are.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .stems:
            Section {
                Picker("Default model", selection: $settings.defaultStemModel) {
                    ForEach(DJStemModel.allCases) { model in
                        Text("\(model.title) (\(model.modelName))").tag(model)
                    }
                }
                Text(settings.defaultStemModel.helper)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Keep", selection: $settings.stemChoice) {
                    Text("All stems").tag(DJStemChoice.all)
                    Text("Acapella + Instrumental").tag(DJStemChoice.acapellaInstrumental)
                }
                FormatPicker(title: "Save stems as", selection: $settings.stemsFormat)
            } footer: {
                Text("Stems are named “Artist - Title (Vocals)” and tagged like the track, so they sit together in Rekordbox or Serato. The instrumental is every stem but the vocals, mixed back together. Pick single stems on a track's Stems card.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .apollo:
            Section {
                FormatPicker(title: "Save repairs as", selection: $settings.repairFormat)
                if !settings.repairFormat.isLossless {
                    Label("MP3 cuts the highs the repair just rebuilt (even 320 kbps stops around 20 kHz). Lossless is recommended.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(DJColor.marker)
                }
            }
            Section {
                LabeledContent("Status", value: apolloStatus)
                Button("Remove Repair Model…", role: .destructive) { isConfirmingReset = true }
                    .disabled(isResetting || model.apolloState == .notInstalled || model.apolloState.isInstalling)
            } header: {
                Text("Model")
            } footer: {
                Text("Removes the downloaded model (about 66 MB) from Application Support. The next repair downloads it again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .loudness:
            Section {
                Picker("Target loudness", selection: $settings.targetLUFS) {
                    ForEach(AppSettings.targetChoices, id: \.self) { lufs in
                        Text(lufs == AppSettings.defaultTargetLUFS ? "\(DJFormat.lufs(lufs, decimals: 0)) (default)" : DJFormat.lufs(lufs, decimals: 0))
                            .tag(lufs)
                    }
                }
                Text("Club masters sit around −6 to −9 LUFS; −14 LUFS is streaming level.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("True-peak ceiling", selection: $settings.ceilingDBTP) {
                    ForEach(AppSettings.ceilingChoices, id: \.self) { dBTP in
                        Text(dBTP == AppSettings.defaultCeilingDBTP ? "\(DJFormat.dBTP(dBTP)) (default)" : DJFormat.dBTP(dBTP))
                            .tag(dBTP)
                    }
                }
                FormatPicker(title: "Save normalized tracks as", selection: $settings.normalizeFormat)
                Toggle("Also normalize repaired tracks", isOn: $settings.normalizeRepairs)
            } footer: {
                Text("Gain only: never a limiter or compression. When reaching the target would push the true peak past the ceiling, the gain stops at the ceiling and the track lands quieter. Stems are never normalized, so they still sum back to the mix.")
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
                        Text(format == .aiff ? "AIFF — best for Rekordbox" : format.title).tag(format)
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
    case general, trackID, stems, apollo, loudness, credits

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .trackID: "Track ID"
        case .stems: "Stems"
        case .apollo: "Repair"
        case .loudness: "Loudness"
        case .credits: "Credits"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "folder"
        case .trackID: "shazam.logo"
        case .stems: "square.3.layers.3d"
        case .apollo: "wand.and.stars"
        case .loudness: "speaker.wave.2"
        case .credits: "heart"
        }
    }
}
