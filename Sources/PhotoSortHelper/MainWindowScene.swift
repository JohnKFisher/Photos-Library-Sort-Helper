import SwiftUI

struct MainWindowScene: Scene {
    @ObservedObject var viewModel: ReviewViewModel

    var body: some Scene {
        WindowGroup(AppMetadata.displayName) {
            RootView()
                .environmentObject(viewModel)
        }
        .defaultSize(width: 1360, height: 860)
        .windowResizability(.automatic)
        .commands {
            AppCommands(viewModel: viewModel)
        }
    }
}
