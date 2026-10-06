import AppKit
import AudioExport
import SwiftUI

/// Settings (⌘,): where results go and as what, the default stem model, and Apollo.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var isConfirmingReset = false
    @State private var isResetting = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
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
            } header: {
                Text("Results")
            } footer: {
                Text("Stems go in a “(Stems)” folder per track; Apollo writes “<track> (Apollo).\(settings.repairFormat.fileExtension)”. AIFF, FLAC and MP3 carry the track's title, artist, album and artwork.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Stems") {
                Picker("Default model", selection: $settings.defaultStemModel) {
                    ForEach(DJStemModel.allCases) { model in
                        Text("\(model.title) (\(model.modelName))").tag(model)
                    }
                }
                Text(settings.defaultStemModel.helper)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FormatPicker(title: "Save stems as", selection: $settings.stemsFormat)
            }

            Section {
                FormatPicker(title: "Save repairs as", selection: $settings.repairFormat)
                if !settings.repairFormat.isLossless {
                    Label("MP3 cuts the highs Apollo just rebuilt (even 320 kbps stops around 20 kHz). Lossless is recommended.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(DJColor.marker)
                }
                LabeledContent("Status", value: apolloStatus)
                Button("Reset Apollo Runtime…", role: .destructive) { isConfirmingReset = true }
                    .disabled(isResetting || model.apolloState == .notInstalled || model.apolloState.isInstalling)
            } header: {
                Text("Apollo")
            } footer: {
                Text("Removes the downloaded runtime and model from Application Support. The next repair downloads them again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Credits") {
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

            if model.engines.isFake {
                Section("Engines") {
                    Text("Demo engines: jobs sleep and write placeholder files. Launched with -useFakeEngines, or the engine packages aren't linked yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Reset Apollo's runtime?", isPresented: $isConfirmingReset) {
            Button("Reset", role: .destructive) {
                isResetting = true
                Task {
                    await model.resetApollo()
                    isResetting = false
                }
            }
        } message: {
            Text("Running repairs stop, and the next one downloads about 600 MB again.")
        }
        .task { await model.refreshApolloState() }
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
        if isResetting { return "Resetting…" }
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
