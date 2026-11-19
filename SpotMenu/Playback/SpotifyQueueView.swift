import SwiftUI

struct SpotifyQueueView: View {
    @ObservedObject var playback: PlaybackModel
    let close: () -> Void
    let connect: () -> Void

    @State private var state = LoadState.loading
    @State private var isLoading = true
    @State private var refreshCount = 0
    @State private var contentBottom: CGFloat = .infinity

    private static let scrollSpace = "SpotifyQueueViewport"

    private struct QueueBottom: PreferenceKey {
        static let defaultValue: CGFloat = .infinity

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

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
                Button(action: close) {
                    Image(systemName: "xmark")
                        .frame(width: 26, height: 26)
                }
                .accessibilityLabel("Close queue")
                .help("Close queue")

                Spacer()
                Text("Up Next").font(.headline)
                Spacer()

                ZStack {
                    if isLoading {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Refreshing queue")
                    }
                }
                .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()
            GeometryReader { viewport in
                ScrollView {
                    queueContent
                        .frame(
                            minHeight: viewport.size.height,
                            alignment: contentAlignment
                        )
                        .background {
                            GeometryReader { content in
                                Color.clear.preference(
                                    key: QueueBottom.self,
                                    value: content.frame(in: .named(Self.scrollSpace)).maxY
                                )
                            }
                        }
                }
                .coordinateSpace(name: Self.scrollSpace)
                .onPreferenceChange(QueueBottom.self) { contentBottom = $0 }
                .background {
                    QueuePullObserver(
                        atBottom: contentBottom <= viewport.size.height + 2,
                        refresh: requestRefresh
                    )
                }
            }
        }
        .frame(width: 300, height: 300)
        .background(.regularMaterial)
        .accessibilityAction(named: Text("Refresh queue"), requestRefresh)
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
            ProgressView("Loading queue…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let items) where items.isEmpty:
            message("No upcoming tracks or episodes.")
        case .loaded(let items):
            LazyVStack(alignment: .leading, spacing: 0) {
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
        defer {
            if !Task.isCancelled { isLoading = false }
        }
        do {
            let items = try await SpotifyQueue.load()
            guard !Task.isCancelled else { return }
            state = .loaded(items)
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error as? SpotifyQueue.LoadError, message: error.localizedDescription)
        }
    }
}
