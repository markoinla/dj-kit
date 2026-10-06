import SwiftUI

/// Apollo's one-time setup: what gets downloaded, an Install button, and
/// the installer's status lines as they come.
struct ApolloSetupSheet: View {
    @Environment(AppModel.self) private var model
    let request: ApolloSetupRequest

    var body: some View {
        ApolloSetupContent(
            state: model.apolloState,
            trackCount: request.trackIDs.count,
            install: { model.installApollo() },
            close: { model.dismissApolloSetup() }
        )
    }
}

/// The sheet's content, driven by plain values (also drawn by `-renderPreviews`).
struct ApolloSetupContent: View {
    let state: DJApolloSetupState
    let trackCount: Int
    var install: () -> Void = {}
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: DJSpace.lg) {
            HStack(alignment: .top, spacing: DJSpace.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: DJRadius.lg).fill(DJColor.ring.opacity(0.15))
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(DJColor.ring)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set up Repair")
                        .font(.dj(17, weight: 650))
                        .tracking(-0.2)
                        .foregroundStyle(DJColor.foreground)
                    Text("One-time 66 MB download. Runs offline after that.")
                        .djText(.body)
                        .foregroundStyle(DJColor.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 0) {
                item("cpu", "Apollo model", "Hugging Face · CC BY-SA 4.0")
                DJDivider()
                item("bolt", "On the GPU", "About half the track's length")
                DJDivider()
                item("internaldrive", "Application Support", "Remove it in Settings ▸ Repair")
            }
            .djCard()

            status

            HStack(spacing: DJSpace.sm) {
                if trackCount > 0 {
                    Text(trackCount == 1 ? "Your track runs after setup" : "\(trackCount) tracks run after setup")
                        .djText(.caption)
                        .foregroundStyle(DJColor.mutedForeground)
                }
                Spacer()
                Button(state.isInstalling ? "Hide" : "Cancel", action: close)
                    .buttonStyle(.dj(.outline))
                    .keyboardShortcut(.cancelAction)
                Button(installTitle, action: install)
                    .buttonStyle(.dj(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.isInstalling || state == .ready)
            }
        }
        .padding(DJSpace.xxl)
        .frame(width: 500)
        .background(DJColor.background)
    }

    private var installTitle: String {
        switch state {
        case .installing: "Installing…"
        case .failed: "Try Again"
        case .ready: "Installed"
        case .notInstalled: "Install"
        }
    }

    @ViewBuilder private var status: some View {
        switch state {
        case .installing(let line):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(line)
                        .djText(.bodyMedium)
                        .foregroundStyle(DJColor.foreground)
                        .monospacedDigit()
                        .lineLimit(1)
                    Spacer()
                }
                DJProgressBar(fraction: nil, height: 4, tint: DJColor.ring)
            }
            .djTray()
        case .failed(let message):
            DJNotice(kind: .error, message: "Setup failed: \(message)")
        case .ready:
            DJNotice(kind: .info, message: "Repair is ready.")
        case .notInstalled:
            EmptyView()
        }
    }

    private func item(_ systemImage: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: DJSpace.md) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(DJColor.mutedForeground)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).djText(.bodyMedium).foregroundStyle(DJColor.foreground)
                Text(detail)
                    .djText(.caption)
                    .foregroundStyle(DJColor.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DJSpace.md)
        .padding(.vertical, 10)
    }
}
