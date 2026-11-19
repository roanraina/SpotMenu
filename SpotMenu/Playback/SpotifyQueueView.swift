import SwiftUI

struct SpotifyQueueView: View {
    @ObservedObject var playback: PlaybackModel
    let close: () -> Void
    let connect: () -> Void

    @State private var state = LoadState.loading
    @State private var isLoading = true
    @State private var refreshCount = 0

    private enum LoadState {
        case loading
        case loaded([SpotifyQueue.Item])
        case failed(SpotifyQueue.LoadError?, message: String)
    }

    private struct Refresh: Equatable {
        let trackURI: String?
        let count: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if isLoading {
                    ProgressView().controlSize(.small)
                    Text("Refreshing queue…").font(.headline)
                } else {
                    Text("Up Next").font(.headline)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 46)

            Divider()
            GeometryReader { viewport in
                QueueScrollView(viewport: viewport.size, refresh: requestRefresh) {
                    queueContent
                        .frame(width: viewport.size.width, alignment: contentAlignment)
                        .frame(minHeight: viewport.size.height, alignment: contentAlignment)
                }
            }
        }
        .frame(width: 300, height: 300)
        .background(.regularMaterial)
        .accessibilityAction(named: Text("Refresh queue"), requestRefresh)
        .onExitCommand(perform: close)
        .task(id: Refresh(trackURI: playback.spotifyTrackURI, count: refreshCount)) {
            await load()
        }
        .onChange(of: playback.playerType) { player in
            if player != .spotify { close() }
        }
    }

    private var contentAlignment: Alignment {
        if case .loaded(let items) = state, !items.isEmpty { return .topLeading }
        return .center
    }

    @ViewBuilder private var queueContent: some View {
        switch state {
        case .loading:
            Color.clear
        case .loaded(let items) where items.isEmpty:
            message("No upcoming tracks or episodes.")
        case .loaded(let items):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).lineLimit(1)
                        if let subtitle = item.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.vertical, 4)
        case .failed(.signInRequired, let detail):
            message(detail, button: "Connect Spotify")
        case .failed(.insufficientScope, let detail):
            message(detail, button: "Reconnect Spotify")
        case .failed(_, let detail):
            message(detail)
        }
    }

    private func message(_ text: String, button: String? = nil) -> some View {
        VStack(spacing: 12) {
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let button {
                Button(button, action: connect)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func requestRefresh() {
        guard !isLoading else { return }
        isLoading = true
        refreshCount += 1
    }

    @MainActor private func load() async {
        isLoading = true
        let started = ProcessInfo.processInfo.systemUptime
        let result: LoadState
        do {
            let items = try await SpotifyQueue.load()
            result = .loaded(items)
        } catch {
            result = .failed(error as? SpotifyQueue.LoadError, message: error.localizedDescription)
        }
        let remaining = 0.8 - (ProcessInfo.processInfo.systemUptime - started)
        if remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        guard !Task.isCancelled else { return }
        state = result
        isLoading = false
    }
}
