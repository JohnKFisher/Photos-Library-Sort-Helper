import SwiftUI

enum AppWindowID: String {
    case about
}

enum ReviewFocusArea: Hashable {
    case review
}

@MainActor
final class AppCommandRouter: ObservableObject {
    @Published private(set) var reviewFocusRequest = UUID()

    func requestReviewFocus() {
        reviewFocusRequest = UUID()
    }
}

struct ReviewCommandContext {
    var hasPreviousGroup: Bool
    var hasNextGroup: Bool
    var hasHighlight: Bool
    var canQueueForEdit: Bool
    var previousGroup: () -> Void
    var nextGroup: () -> Void
    var previousItem: () -> Void
    var nextItem: () -> Void
    var toggleKeepDiscard: () -> Void
    var keepOnlyHighlighted: () -> Void
    var queueHighlightedForEdit: () -> Void
}

private struct ReviewCommandContextKey: FocusedValueKey {
    typealias Value = ReviewCommandContext
}

extension FocusedValues {
    var reviewCommandContext: ReviewCommandContext? {
        get { self[ReviewCommandContextKey.self] }
        set { self[ReviewCommandContextKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    @ObservedObject var viewModel: ReviewViewModel
    @ObservedObject var commandRouter: AppCommandRouter
    @FocusedValue(\.reviewCommandContext) private var reviewCommandContext
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    var body: some Commands {
        SidebarCommands()
        InspectorCommands()

        CommandGroup(replacing: .appInfo) {
            Button("About \(AppMetadata.displayName)") {
                openWindow(id: AppWindowID.about.rawValue)
            }
        }

        CommandGroup(after: .newItem) {
            Button("Choose Folder...") {
                viewModel.changeSourceFolder()
            }
            .keyboardShortcut("O", modifiers: [.command, .shift])

            Button("Open Selected Folder") {
                viewModel.openSelectedFolder()
            }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(!viewModel.canRevealSourceFolder)

            Button("Reveal Source Folder In Finder") {
                viewModel.revealSourceFolderInFinder()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!viewModel.canRevealSourceFolder)

            Menu("Reveal Queue Destinations") {
                Button("Destination Root") {
                    viewModel.revealSourceFolderInFinder()
                }
                .disabled(!viewModel.canRevealQueueDestinations)

                Button("Files to Edit") {
                    viewModel.revealQueueDestinationInFinder(.editQueue)
                }
                .disabled(!viewModel.canRevealQueueDestinations)

                Button("Files to Manually Delete") {
                    viewModel.revealQueueDestinationInFinder(.manualDeleteQueue)
                }
                .disabled(!viewModel.canRevealQueueDestinations)

                Button("Keep") {
                    viewModel.revealQueueDestinationInFinder(.keep)
                }
                .disabled(!viewModel.canRevealQueueDestinations)
            }

            Divider()

            Button("Open Highlighted Item In Finder") {
                viewModel.revealHighlightedItemInFinder()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(!viewModel.canRevealHighlightedItemInFinder)
        }

        CommandMenu("Review") {
            Button("Scan for Similar Media") {
                viewModel.requestScan()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(viewModel.isScanning || !viewModel.canInitiateScan)

            Button("Stop Scan") {
                viewModel.stopScan()
            }
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(!viewModel.isScanning)

            Divider()

            Button("Previous Group") {
                reviewCommandContext?.previousGroup()
            }
            .keyboardShortcut("[", modifiers: [.command])
            .disabled(!(reviewCommandContext?.hasPreviousGroup ?? false))

            Button("Next Group") {
                reviewCommandContext?.nextGroup()
            }
            .keyboardShortcut("]", modifiers: [.command])
            .disabled(!(reviewCommandContext?.hasNextGroup ?? false))

            Divider()

            Button("Highlight Previous Item") {
                reviewCommandContext?.previousItem()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])
            .disabled(!(reviewCommandContext?.hasHighlight ?? false))

            Button("Highlight Next Item") {
                reviewCommandContext?.nextItem()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command])
            .disabled(!(reviewCommandContext?.hasHighlight ?? false))

            Button("Toggle Highlighted Keep/Discard") {
                reviewCommandContext?.toggleKeepDiscard()
            }
            .keyboardShortcut("`", modifiers: [.command])
            .disabled(!(reviewCommandContext?.hasHighlight ?? false))

            Button("Keep Only Highlighted Item") {
                reviewCommandContext?.keepOnlyHighlighted()
            }
            .keyboardShortcut("k", modifiers: [.command])
            .disabled(!(reviewCommandContext?.hasHighlight ?? false))

            Button("Queue Highlighted Item For Edit") {
                reviewCommandContext?.queueHighlightedForEdit()
            }
            .keyboardShortcut("e", modifiers: [.command])
            .disabled(!(reviewCommandContext?.canQueueForEdit ?? false))

            Divider()

            Button(viewModel.selectedSourceKind == .photos ? "Open Summary And Queue" : "Open Summary And Commit") {
                viewModel.confirmQueueMarkedAssetsForManualDelete()
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!viewModel.canOpenSummary)
        }

        CommandGroup(after: .sidebar) {
            Button("Focus Review Pane") {
                commandRouter.requestReviewFocus()
            }
            .keyboardShortcut("2", modifiers: [.command])
        }

        CommandGroup(after: .help) {
            Divider()

            Button("Project On GitHub") {
                openURL(AppMetadata.repositoryURL)
            }
        }
    }
}
