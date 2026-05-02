import AppKit
import SwiftUI

enum AppWindowID: String {
    case about
}

struct AppCommands: Commands {
    @ObservedObject var viewModel: ReviewViewModel
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
                viewModel.previousGroup()
            }
            .keyboardShortcut("[", modifiers: [.command])
            .disabled(!viewModel.hasPreviousGroup)

            Button("Next Group") {
                viewModel.nextGroup()
            }
            .keyboardShortcut("]", modifiers: [.command])
            .disabled(!viewModel.hasNextGroup)

            Divider()

            Button("Highlight Previous Item") {
                viewModel.highlightPreviousAssetInCurrentGroup()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])
            .disabled(!viewModel.hasHighlightInCurrentGroup)

            Button("Highlight Next Item") {
                viewModel.highlightNextAssetInCurrentGroup()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command])
            .disabled(!viewModel.hasHighlightInCurrentGroup)

            Button("Toggle Highlighted Keep/Discard") {
                viewModel.toggleHighlightedAssetInCurrentGroup()
            }
            .keyboardShortcut("`", modifiers: [.command])
            .disabled(!viewModel.hasHighlightInCurrentGroup)

            Button("Keep Only Highlighted Item") {
                guard
                    let group = viewModel.currentGroup,
                    let itemID = viewModel.highlightedAssetID(in: group)
                else {
                    return
                }
                viewModel.keepOnly(assetID: itemID, in: group)
            }
            .keyboardShortcut("k", modifiers: [.command])
            .disabled(!viewModel.hasHighlightInCurrentGroup)

            Button("Queue Highlighted Item For Edit") {
                viewModel.queueHighlightedAssetForEditingInCurrentGroup()
            }
            .keyboardShortcut("e", modifiers: [.command])
            .disabled(!viewModel.hasHighlightInCurrentGroup || viewModel.isQueuingForEdit)

            Divider()

            Button(viewModel.selectedSourceKind == .photos ? "Open Summary And Queue" : "Open Summary And Commit") {
                viewModel.confirmQueueMarkedAssetsForManualDelete()
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!viewModel.canOpenSummary)
        }

        CommandGroup(after: .sidebar) {
            Button("Focus Review Pane") {
                NSApp.keyWindow?.makeFirstResponder(nil)
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
