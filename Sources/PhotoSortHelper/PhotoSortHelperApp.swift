import SwiftUI

@main
struct PhotosLibrarySortHelperApp: App {
    @StateObject private var viewModel = ReviewViewModel()
    @StateObject private var commandRouter = AppCommandRouter()

    var body: some Scene {
        MainWindowScene(viewModel: viewModel, commandRouter: commandRouter)

        Window("About \(AppMetadata.displayName)", id: AppWindowID.about.rawValue) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        Settings {
            PreferencesView()
                .environmentObject(viewModel)
        }
    }
}
