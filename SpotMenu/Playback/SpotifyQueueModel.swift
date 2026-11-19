import Combine
import Foundation

@MainActor final class SpotifyQueueModel: ObservableObject {
    enum LoadState {
        case pending
        case loaded([SpotifyQueue.Item])
        case failed(SpotifyQueue.LoadError?, message: String)
    }

    @Published private(set) var state = LoadState.pending
    @Published private(set) var isLoading = false

    private var isActive = false
    private var trackURI: String?
    private var loadTask: Task<Void, Never>?

    func update(isActive: Bool, trackURI: String?) {
        let trackURI = isActive ? trackURI : nil
        guard self.isActive != isActive || self.trackURI != trackURI else { return }
        self.isActive = isActive
        self.trackURI = trackURI

        if isActive {
            load()
        } else {
            loadTask?.cancel()
            loadTask = nil
            state = .pending
            isLoading = false
        }
    }

    func refresh() {
        guard isActive, !isLoading else { return }
        load()
    }

    private func load() {
        loadTask?.cancel()
        isLoading = true
        loadTask = Task { [weak self] in
            let result: LoadState
            do {
                result = .loaded(try await SpotifyQueue.load())
            } catch {
                result = .failed(error as? SpotifyQueue.LoadError, message: error.localizedDescription)
            }
            guard let self, !Task.isCancelled else { return }
            self.state = result
            self.isLoading = false
            self.loadTask = nil
        }
    }
}
