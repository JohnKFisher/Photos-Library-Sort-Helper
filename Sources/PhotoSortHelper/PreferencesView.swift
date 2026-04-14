import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject private var viewModel: ReviewViewModel

    var body: some View {
        Form {
            Section("Default Review Behavior") {
                Picker("Review mode", selection: Binding(
                    get: { viewModel.reviewMode },
                    set: { viewModel.requestReviewModeChange($0) }
                )) {
                    ForEach(ReviewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(viewModel.reviewModeSetupDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle("Include videos in scans", isOn: $viewModel.includeVideos)
                Toggle("Autoplay videos in preview", isOn: $viewModel.autoplayPreviewVideos)
                Toggle("Move kept folder items into Keep by default", isOn: $viewModel.moveKeptItemsToKeepFolder)

                Stepper(value: $viewModel.maxTimeGapSeconds, in: 2...30, step: 1) {
                    Text("Max time gap: \(Int(viewModel.maxTimeGapSeconds)) seconds")
                }

                Text("These defaults apply to new scans. Source scope, album choice, and the active folder stay in the main review window.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Recent Folders") {
                if viewModel.recentFolderOptions.isEmpty {
                    Text("No recent folders yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.recentFolderOptions, id: \.resolvedPath) { selection in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(selection.displayName)
                                Text(selection.resolvedPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }

                            Spacer()

                            Button("Use") {
                                viewModel.selectRecentFolder(selection)
                            }
                            .buttonStyle(.borderless)

                            Button("Remove", role: .destructive) {
                                viewModel.removeRecentFolder(selection)
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    Button("Clear Recent Folders", role: .destructive) {
                        viewModel.clearRecentFolders()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
        .alert("Change Review Mode?", isPresented: $viewModel.showReviewModeResetConfirmation) {
            Button("Cancel", role: .cancel) {
                viewModel.cancelReviewModeChange()
            }
            Button("Change Mode And Reset", role: .destructive) {
                viewModel.confirmReviewModeChange()
            }
        } message: {
            Text("Changing review mode clears the current review session and requires a fresh scan. Existing queued selections will be lost.")
        }
    }
}
