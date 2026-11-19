import SwiftUI

struct SpotifyQueueView: View {
    @ObservedObject var model: SpotifyQueueModel
    let close: () -> Void
    let connect: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Queue")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 46)

            Divider()
            GeometryReader { viewport in
                QueueScrollView(viewport: viewport.size, refresh: model.refresh) {
                    VStack(spacing: 0) {
                        if model.isLoading {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                                .accessibilityLabel("Refreshing queue")
                                .padding(.vertical, 8)
                        }
                        queueContent
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: viewport.size.width)
                    .frame(minHeight: viewport.size.height, alignment: contentAlignment)
                }
            }
        }
        .frame(width: 300, height: 300)
        .background(.regularMaterial)
        .accessibilityAction(named: Text("Refresh queue"), model.refresh)
        .onExitCommand(perform: close)
    }

    private var contentAlignment: Alignment {
        if model.isLoading { return .top }
        if case .loaded(let items) = model.state, !items.isEmpty { return .top }
        return .center
    }

    @ViewBuilder private var queueContent: some View {
        switch model.state {
        case .pending:
            EmptyView()
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
}
