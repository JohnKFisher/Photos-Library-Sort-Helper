import SwiftUI

@main
struct PhotosLibrarySortHelperApp: App {
    @StateObject private var viewModel = ReviewViewModel()

    var body: some Scene {
        MainWindowScene(viewModel: viewModel)

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
