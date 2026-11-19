import SwiftUI

class LoginWindowManager {
    private static var loginWindow: NSWindow?
    private static var includesQueue = false

    static func showLoginWindow(
        with preferences: MusicPlayerPreferencesModel,
        includeQueue: Bool = false
    ) {
        if let loginWindow, loginWindow.isVisible, includesQueue == includeQueue {
            loginWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        loginWindow?.close()
        includesQueue = includeQueue
        SpotifyAuthManager.shared.didAuthenticate = false
        let view = SpotifyLoginView(preferences: preferences, includeQueue: includeQueue)
        let hosting = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.title = "Log In to Spotify"
        window.isReleasedWhenClosed = false
        loginWindow = window

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
