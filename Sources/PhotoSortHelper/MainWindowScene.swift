import SwiftUI

struct MainWindowScene: Scene {
    @ObservedObject var viewModel: ReviewViewModel
    @ObservedObject var commandRouter: AppCommandRouter

    var body: some Scene {
        WindowGroup(AppMetadata.displayName) {
            RootView()
                .environmentObject(viewModel)
                .environmentObject(commandRouter)
        }
        .defaultSize(width: 1360, height: 860)
        .windowResizability(.automatic)
        .commands {
            AppCommands(viewModel: viewModel, commandRouter: commandRouter)
        }
    }
}
