import AppKit
import SwiftUI

@main
struct PhotosLibrarySortHelperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = ReviewViewModel()
    @State private var isShowingAbout = false

    var body: some Scene {
        WindowGroup(AppMetadata.displayName) {
            RootView()
                .environmentObject(viewModel)
                .frame(minWidth: 960, idealWidth: 1280, minHeight: 780, idealHeight: 820)
                .sheet(isPresented: $isShowingAbout) {
                    AboutSheet()
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(AppMetadata.displayName)") {
                    isShowingAbout = true
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
}

private struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(AppMetadata.displayName)
                    .font(.title2.weight(.semibold))

                Text(AppMetadata.releaseLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(AppMetadata.copyrightNotice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text(AppMetadata.aboutSummary)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Link("View project on GitHub", destination: AppMetadata.repositoryURL)
                .font(.body.weight(.semibold))

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(minWidth: 420)
    }
}
