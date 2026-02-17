import SwiftUI

@main
struct PhotoSortHelperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = ReviewViewModel()

    var body: some Scene {
        WindowGroup("Photo Sort Helper") {
            RootView()
                .environmentObject(viewModel)
                .frame(minWidth: 1140, minHeight: 780)
        }
        .commands {
            CommandMenu("Review Navigation") {
                Button("Previous Group") {
                    viewModel.previousGroup()
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!viewModel.hasPreviousGroup)

                Button("Next Group") {
                    viewModel.nextGroup()
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!viewModel.hasNextGroup)

                Divider()

                Button("Highlight Previous Item") {
                    viewModel.highlightPreviousAssetInCurrentGroup()
                }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(!viewModel.hasHighlightInCurrentGroup)

                Button("Highlight Next Item") {
                    viewModel.highlightNextAssetInCurrentGroup()
                }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(!viewModel.hasHighlightInCurrentGroup)

                Button("Toggle Highlighted Keep/Discard") {
                    viewModel.toggleHighlightedAssetInCurrentGroup()
                }
                .keyboardShortcut("`", modifiers: [])
                .disabled(!viewModel.hasHighlightInCurrentGroup)
            }
        }
    }
}
