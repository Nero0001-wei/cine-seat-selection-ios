import SwiftUI

@main
struct CinemaDemoApp: App {
    var body: some Scene {
        WindowGroup {
            CinemaRootView()
                .preferredColorScheme(.dark)
                .tint(CinemaTheme.accent)
        }
    }
}
