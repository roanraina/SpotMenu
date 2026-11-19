import SwiftUI

struct MusicPlayerPreferencesView: View {
    @ObservedObject var model: MusicPlayerPreferencesModel
    @ObservedObject var playbackModel: PlaybackModel
    @State private var isTestingQueue = false
    @State private var queueStatus: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Form {
                    Section {
                        Picker("Preferred Player", selection: $model.preferredMusicApp) {
                            ForEach(PreferredPlayer.allCases) { player in
                                Text(player.displayName).tag(player)
                            }
                        }
                    } header: {
                        Text("Music Player")
                    } footer: {
                        Text(
                            "\"Automatic\" selects the first available app at launch. If both Spotify and Apple Music are installed or running, Spotify is preferred."
                        )
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)

                if playbackModel.isLikingImplemented {
                    Form {
                        Section("Spotify Playback") {
                            Toggle(
                                "Show Shuffle and Repeat",
                                isOn: $model.showShuffleAndRepeat
                            )
                        }

                        Section {
                            Toggle("Enable Track Liking", isOn: $model.likingEnabled)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Spotify Client ID")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField(
                                    "Enter Spotify Client ID",
                                    text: Binding(
                                        get: { model.spotifyClientID ?? "" },
                                        set: { newValue in
                                            let trimmed = newValue.trimmingCharacters(
                                                in: .whitespacesAndNewlines
                                            )
                                            model.spotifyClientID =
                                                trimmed.isEmpty ? nil : trimmed
                                        }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                            }

                            HStack {
                                if isTestingQueue {
                                    ProgressView().controlSize(.small)
                                }
                                Spacer()
                                Button("Test Queue", action: testQueue)
                                    .disabled(isTestingQueue)
                                Button("Connect / Reconnect Spotify") {
                                    LoginWindowManager.showLoginWindow(with: model)
                                }
                            }
                            if let queueStatus {
                                Text(queueStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        } header: {
                            Text("Spotify Integration")
                        } footer: {
                            Text("Connect Spotify for Up Next. Turn on Track Liking if you also want to grant library access.")
                        }
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: 600)
            .padding(20)
        }
    }

    @MainActor private func testQueue() {
        isTestingQueue = true
        queueStatus = nil
        Task {
            defer { isTestingQueue = false }
            do {
                let items = try await SpotifyQueue.load()
                queueStatus = items.isEmpty
                    ? "Queue access works. Spotify has no upcoming tracks or episodes."
                    : "Queue access works. Spotify returned \(items.count) upcoming items."
            } catch {
                queueStatus = error.localizedDescription
            }
        }
    }
}

#Preview {
    MusicPlayerPreferencesView(
        model: MusicPlayerPreferencesModel(),
        playbackModel: PlaybackModel(preferences: MusicPlayerPreferencesModel())
    )
}
