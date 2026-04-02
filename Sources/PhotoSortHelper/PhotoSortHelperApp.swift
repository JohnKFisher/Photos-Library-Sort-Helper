import AppKit
import SwiftUI

@main
struct PhotosLibrarySortHelperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = ReviewViewModel()

    var body: some Scene {
        WindowGroup(AppMetadata.displayName) {
            RootView()
                .environmentObject(viewModel)
                .frame(minWidth: 960, idealWidth: 1280, minHeight: 780, idealHeight: 820)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(AppMetadata.displayName)") {
                    NSApp.orderFrontStandardAboutPanel(options: aboutPanelOptions)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }

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

                Button("Send Highlighted to Files to Edit") {
                    viewModel.queueHighlightedAssetForEditingInCurrentGroup()
                }
                .keyboardShortcut("e", modifiers: [])
                .disabled(!viewModel.hasHighlightInCurrentGroup || viewModel.isQueuingForEdit)
            }
        }
    }

    private var aboutPanelOptions: [NSApplication.AboutPanelOptionKey: Any] {
        [
            .applicationName: AppMetadata.displayName,
            .applicationVersion: AppMetadata.version,
            .version: "Build \(AppMetadata.build)",
            .credits: NSAttributedString(string: "Photos Library Sort Helper \(AppMetadata.version)\nReview similar photos safely. Marked items can be queued to \"Files to Manually Delete\" for human review in Photos.")
        ]
    }
}
