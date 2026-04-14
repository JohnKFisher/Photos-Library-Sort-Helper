import AppKit
import AVFoundation
import AVKit
import Photos
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var viewModel: ReviewViewModel
    @EnvironmentObject private var commandRouter: AppCommandRouter
    @FocusState private var focusedArea: ReviewFocusArea?
    @SceneStorage("root.sourceSectionExpanded") private var sourceSectionExpanded = true
    @SceneStorage("root.scanSectionExpanded") private var scanSectionExpanded = true
    @SceneStorage("root.reviewSectionExpanded") private var reviewSectionExpanded = true
    @SceneStorage("root.inspectorVisible") private var inspectorVisible = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SourceSidebarView(
                sourceSectionExpanded: $sourceSectionExpanded,
                scanSectionExpanded: $scanSectionExpanded,
                reviewSectionExpanded: $reviewSectionExpanded
            )
            .environmentObject(viewModel)
            .navigationSplitViewColumnWidth(min: 310, ideal: 360, max: 420)
        } detail: {
            reviewContent
                .defaultFocus($focusedArea, .review)
                .focused($focusedArea, equals: .review)
                .focusable()
                .focusedSceneValue(\.reviewCommandContext, focusedArea == .review ? reviewCommandContext : nil)
                .contentShape(Rectangle())
                .onTapGesture {
                    focusedArea = .review
                }
                .overlay {
                    if focusedArea == .review {
                        ReviewKeyBindingHost(
                            previousGroup: viewModel.previousGroup,
                            nextGroup: viewModel.nextGroup,
                            previousItem: viewModel.highlightPreviousAssetInCurrentGroup,
                            nextItem: viewModel.highlightNextAssetInCurrentGroup,
                            toggleKeepDiscard: viewModel.toggleHighlightedAssetInCurrentGroup,
                            queueForEdit: viewModel.queueHighlightedAssetForEditingInCurrentGroup
                        )
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: $inspectorVisible) {
            ReviewInspectorView()
                .environmentObject(viewModel)
                .inspectorColumnWidth(min: 250, ideal: 300, max: 360)
        }
        .task {
            await viewModel.bootstrap()
        }
        .onChange(of: commandRouter.reviewFocusRequest) { _, _ in
            focusedArea = .review
        }
        .onChange(of: viewModel.groups.count) { _, newCount in
            if newCount > 0 && !viewModel.showDeleteConfirmation && !viewModel.showReviewModeResetConfirmation {
                focusedArea = .review
            }
        }
        .onChange(of: viewModel.currentGroupIndex) { _, _ in
            if viewModel.currentGroup != nil && !viewModel.showDeleteConfirmation && !viewModel.showReviewModeResetConfirmation {
                focusedArea = .review
            }
        }
        .onChange(of: viewModel.showDeleteConfirmation) { _, isPresented in
            if !isPresented && viewModel.currentGroup != nil {
                focusedArea = .review
            }
        }
        .onChange(of: viewModel.showReviewModeResetConfirmation) { _, isPresented in
            if !isPresented && viewModel.currentGroup != nil {
                focusedArea = .review
            }
        }
        .sheet(isPresented: $viewModel.showDeleteConfirmation) {
            SessionSummarySheet(isPresented: $viewModel.showDeleteConfirmation)
                .environmentObject(viewModel)
        }
        .alert("Large Selection", isPresented: $viewModel.showLargeSelectionWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Continue Anyway") {
                viewModel.continueScanAfterLargeScopeWarning()
            }
        } message: {
            Text("This scan includes \(viewModel.estimatedScanScopeCount) item(s). We recommend a much smaller selection.")
        }
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
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { newValue in
                if !newValue {
                    viewModel.errorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if viewModel.selectedSourceKind == .folder {
                    Button("Choose Folder", systemImage: "folder.badge.plus") {
                        viewModel.changeSourceFolder()
                    }
                }
            }

            ToolbarItem(placement: .principal) {
                Label(viewModel.currentSourceSummary, systemImage: viewModel.selectedSourceKind == .photos ? "photo.stack" : "folder")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if viewModel.canRevealSourceFolder {
                    Menu("Reveal", systemImage: "folder") {
                        Button("Open Selected Folder") {
                            viewModel.openSelectedFolder()
                        }

                        Button("Reveal Source Folder In Finder") {
                            viewModel.revealSourceFolderInFinder()
                        }

                        if viewModel.canRevealQueueDestinations {
                            Divider()

                            Button("Reveal Files to Edit") {
                                viewModel.revealQueueDestinationInFinder(.editQueue)
                            }

                            Button("Reveal Files to Manually Delete") {
                                viewModel.revealQueueDestinationInFinder(.manualDeleteQueue)
                            }

                            Button("Reveal Keep") {
                                viewModel.revealQueueDestinationInFinder(.keep)
                            }
                        }

                        if viewModel.canRevealHighlightedItemInFinder {
                            Divider()
                            Button("Reveal Highlighted Item") {
                                viewModel.revealHighlightedItemInFinder()
                            }
                        }
                    }
                }

                Button(viewModel.isScanning ? "Stop Scan" : "Scan", systemImage: viewModel.isScanning ? "stop.fill" : "magnifyingglass") {
                    if viewModel.isScanning {
                        viewModel.stopScan()
                    } else {
                        viewModel.requestScan()
                    }
                }
                .disabled(viewModel.isScanning ? false : !viewModel.canInitiateScan)

                Button(viewModel.selectedSourceKind == .photos ? "Summary" : "Commit Summary", systemImage: "checklist") {
                    viewModel.confirmQueueMarkedAssetsForManualDelete()
                }
                .disabled(!viewModel.canOpenSummary)

                Button(inspectorVisible ? "Hide Inspector" : "Show Inspector", systemImage: inspectorVisible ? "sidebar.right" : "sidebar.right") {
                    inspectorVisible.toggle()
                }
            }
        }
    }

    private var reviewContent: some View {
        Group {
            if viewModel.selectedSourceKind == .photos && !viewModel.isAuthorized {
                ContentUnavailableView(
                    "Photo Access Needed",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Use Scan for Similar Media to request access only when you are ready to review your library.")
                )
            } else if viewModel.selectedSourceKind == .folder && viewModel.folderSelection == nil {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "Choose A Folder",
                        systemImage: "folder",
                        description: Text("Pick a source folder, then run a scan to load similar media groups.")
                    )

                    Button("Choose Folder...") {
                        viewModel.changeSourceFolder()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if let group = viewModel.currentGroup {
                ReviewGroupView(group: group)
                    .environmentObject(viewModel)
            } else {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        viewModel.selectedSourceKind == .folder ? "No Group Selected" : "No Group Selected",
                        systemImage: viewModel.selectedSourceKind == .folder ? "folder.badge.questionmark" : "photo.stack",
                        description: Text(viewModel.selectedSourceKind == .folder ? "Run a scan to load similar-media groups, or open the selected folder in Finder first." : "Run a scan to load similar-media groups.")
                    )

                    if viewModel.selectedSourceKind == .folder {
                        Button("Open Selected Folder") {
                            viewModel.openSelectedFolder()
                        }
                        .disabled(!viewModel.canRevealSourceFolder)
                    }

                    Button("Scan for Similar Media") {
                        viewModel.requestScan()
                    }
                    .disabled(viewModel.isScanning || !viewModel.canInitiateScan)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var reviewCommandContext: ReviewCommandContext {
        ReviewCommandContext(
            hasPreviousGroup: viewModel.hasPreviousGroup,
            hasNextGroup: viewModel.hasNextGroup,
            hasHighlight: viewModel.hasHighlightInCurrentGroup,
            canQueueForEdit: viewModel.hasHighlightInCurrentGroup && !viewModel.isQueuingForEdit,
            previousGroup: viewModel.previousGroup,
            nextGroup: viewModel.nextGroup,
            previousItem: viewModel.highlightPreviousAssetInCurrentGroup,
            nextItem: viewModel.highlightNextAssetInCurrentGroup,
            toggleKeepDiscard: viewModel.toggleHighlightedAssetInCurrentGroup,
            keepOnlyHighlighted: {
                guard
                    let group = viewModel.currentGroup,
                    let itemID = viewModel.highlightedAssetID(in: group)
                else {
                    return
                }
                viewModel.keepOnly(assetID: itemID, in: group)
            },
            queueHighlightedForEdit: viewModel.queueHighlightedAssetForEditingInCurrentGroup
        )
    }
}

private struct SourceSidebarView: View {
    @EnvironmentObject private var viewModel: ReviewViewModel
    @Binding var sourceSectionExpanded: Bool
    @Binding var scanSectionExpanded: Bool
    @Binding var reviewSectionExpanded: Bool
    @State private var folderDropIsTargeted = false

    var body: some View {
        Form {
            if viewModel.selectedSourceKind == .photos {
                Section {
                    authorizationSection
                }
            }

            Section {
                DisclosureGroup("Source", isExpanded: $sourceSectionExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Source type", selection: $viewModel.selectedSourceKind) {
                            ForEach(ReviewSourceKind.allCases) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)

                        if viewModel.selectedSourceKind == .photos {
                            Picker("Look in", selection: $viewModel.sourceMode) {
                                ForEach(PhotoSourceMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)

                            if viewModel.sourceMode == .album {
                                if viewModel.albums.isEmpty {
                                    Text("No albums available.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Picker("Album", selection: Binding(
                                        get: { viewModel.selectedAlbumID ?? viewModel.albums.first?.id ?? "" },
                                        set: { viewModel.selectedAlbumID = $0 }
                                    )) {
                                        ForEach(viewModel.albums) { album in
                                            Text(album.pickerTitle).tag(album.id)
                                        }
                                    }
                                }
                            }

                            Toggle("Use date range", isOn: $viewModel.useDateRange)
                            if viewModel.useDateRange {
                                DatePicker("From", selection: $viewModel.rangeStartDate, displayedComponents: [.date])
                                DatePicker("To", selection: $viewModel.rangeEndDate, displayedComponents: [.date])
                            }
                        } else {
                            folderSelectionSection
                        }
                    }
                    .padding(.top, 6)
                }
            }

            Section {
                DisclosureGroup("Scan", isExpanded: $scanSectionExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Review mode", selection: Binding(
                            get: { viewModel.reviewMode },
                            set: { viewModel.requestReviewModeChange($0) }
                        )) {
                            ForEach(ReviewMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text(viewModel.reviewModeSetupDescription)
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Stepper(value: $viewModel.maxTimeGapSeconds, in: 2...30, step: 1) {
                            Text("Max time gap: \(Int(viewModel.maxTimeGapSeconds)) seconds")
                        }

                        Toggle("Include videos", isOn: $viewModel.includeVideos)
                        Toggle("Autoplay preview videos", isOn: $viewModel.autoplayPreviewVideos)

                        Label(viewModel.reviewModeStatusText, systemImage: "hand.raised")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(viewModel.reviewMode == .discardFirst ? UITheme.discard : UITheme.keep)

                        Text(viewModel.reviewGuidanceText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Button {
                            viewModel.requestScan()
                        } label: {
                            Label(viewModel.isScanning ? "Scanning..." : "Scan for Similar Media", systemImage: "magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isScanning || !viewModel.canInitiateScan)

                        if viewModel.isScanning {
                            Button(role: .destructive) {
                                viewModel.stopScan()
                            } label: {
                                Label("Stop Scan", systemImage: "stop.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.top, 6)
                }
            }

            Section {
                DisclosureGroup("Review", isExpanded: $reviewSectionExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("Scanned", value: "\(viewModel.scannedAssetCount)")
                        LabeledContent("Groups", value: "\(viewModel.groups.count)")
                        LabeledContent("Clusters", value: "\(viewModel.temporalClusterCount)")
                        LabeledContent("Reviewed", value: "\(viewModel.reviewedGroupCount)/\(viewModel.groups.count)")
                        LabeledContent("Estimated reclaim", value: viewModel.estimatedDiscardSizeLabel)

                        if let deletionMessage = viewModel.deletionMessage {
                            Label(deletionMessage, systemImage: "checkmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(UITheme.keep)
                        }

                        if let editQueueMessage = viewModel.editQueueMessage {
                            Label(editQueueMessage, systemImage: "pencil.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(UITheme.suggested)
                        }

                        Text(viewModel.scanStatusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if viewModel.isScanning {
                            ProgressView(value: viewModel.scanProgress)
                        }
                    }
                    .padding(.top, 6)
                }
            }

            if !viewModel.recentFolderOptions.isEmpty {
                Section("Recent Folders") {
                    ForEach(viewModel.recentFolderOptions, id: \.resolvedPath) { selection in
                        Button {
                            viewModel.selectRecentFolder(selection)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(selection.displayName)
                                Text(selection.resolvedPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .overlay {
            if folderDropIsTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [8, 8]))
                    .foregroundStyle(Color.accentColor)
                    .padding(8)
            }
        }
        .dropDestination(
            for: URL.self,
            action: { urls, _ in
                viewModel.acceptDroppedFolders(urls)
            },
            isTargeted: { folderDropIsTargeted = $0 }
        )
    }

    private var authorizationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Photos Access", systemImage: "photo.on.rectangle.angled")
                .font(.headline)

            Text(PhotoAuthorizationSupport.accessDescription(for: viewModel.authorizationStatus))
                .font(.footnote)
                .foregroundStyle(.secondary)

            if viewModel.authorizationStatus == .notDetermined {
                Button("Request Photos Access") {
                    Task {
                        await viewModel.requestPhotoAccess()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var folderSelectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Choose Folder...") {
                viewModel.changeSourceFolder()
            }
            .buttonStyle(.borderedProminent)

            if viewModel.folderSelection != nil {
                Text(viewModel.folderSelectionDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                HStack {
                    Button("Open Selected Folder") {
                        viewModel.openSelectedFolder()
                    }

                    Button("Reveal In Finder") {
                        viewModel.revealSourceFolderInFinder()
                    }
                }
                .buttonStyle(.link)
            } else {
                Text("Drop a folder here or choose one to review recursively.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Toggle("Also move kept files to Keep", isOn: $viewModel.moveKeptItemsToKeepFolder)
        }
    }
}

private struct ReviewInspectorView: View {
    @EnvironmentObject private var viewModel: ReviewViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Current Focus") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Item", value: viewModel.highlightedItemTitle)
                        LabeledContent("Source", value: viewModel.currentSourceSummary)

                        if let path = viewModel.highlightedItemPath {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Path")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(path)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        } else {
                            Text(viewModel.highlightedItemSecondaryDetail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        if viewModel.canOpenFocusedItem {
                            HStack {
                                Button("Open") {
                                    viewModel.openFocusedItem()
                                }

                                Button("Reveal In Finder") {
                                    viewModel.revealHighlightedItemInFinder()
                                }
                            }
                        }
                    }
                }

                GroupBox("Session") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Groups", value: "\(viewModel.groups.count)")
                        LabeledContent("Reviewed", value: "\(viewModel.reviewedGroupCount)")
                        LabeledContent("Estimated reclaim", value: viewModel.estimatedDiscardSizeLabel)
                        Text(viewModel.scanStatusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if viewModel.selectedSourceKind == .folder && viewModel.canRevealQueueDestinations {
                    GroupBox("Folder Destinations") {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("Destination root", value: viewModel.folderCommitDestinationRootPath)
                            destinationActionRow(title: "Files to Edit", destination: .editQueue)
                            destinationActionRow(title: "Files to Manually Delete", destination: .manualDeleteQueue)
                            destinationActionRow(title: "Keep", destination: .keep)
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func destinationActionRow(title: String, destination: FolderCommitDestination) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(viewModel.folderDestinationPath(for: destination))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Reveal") {
                viewModel.revealQueueDestinationInFinder(destination)
            }
        }
    }
}

private struct SessionSummarySheet: View {
    @EnvironmentObject private var viewModel: ReviewViewModel
    @Binding var isPresented: Bool

    private var canQueue: Bool {
        let hasPendingWork: Bool = {
            switch viewModel.selectedSourceKind {
            case .photos:
                return viewModel.discardCountTotal > 0 || viewModel.keepCountTotal > 0
            case .folder:
                return (viewModel.folderCommitPlan?.totalMoveCount ?? 0) > 0
            }
        }()
        return hasPendingWork && !viewModel.isDeleting && viewModel.deletionArmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Session Summary")
                .font(.title3.bold())

            if viewModel.selectedSourceKind == .photos {
                photosSummary
            } else {
                folderSummary
            }

            HStack {
                Button("Cancel", role: .cancel) {
                    viewModel.deletionArmed = false
                    isPresented = false
                }

                Spacer()

                Button {
                    viewModel.queueMarkedAssetsForManualDelete()
                } label: {
                    if viewModel.isDeleting {
                        Label(viewModel.selectedSourceKind == .photos ? "Queueing..." : "Moving...", systemImage: "hourglass")
                    } else {
                        Text(viewModel.selectedSourceKind == .photos ? "Queue to \"\(viewModel.manualDeleteAlbumName)\"" : "Commit Folder Queues")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canQueue)
            }
        }
        .padding(22)
        .frame(minWidth: 560)
        .onAppear {
            viewModel.deletionArmed = false
        }
    }

    private var photosSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.summaryIntroText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            summaryRow(icon: "checklist", label: "Reviewed groups", value: "\(viewModel.reviewedGroupCount) / \(viewModel.groups.count)")
            summaryRow(icon: "checkmark.circle", label: viewModel.reviewMode == .discardFirst ? "Marked to keep" : "Explicit keeps", value: "\(viewModel.keepCountTotal)", tint: UITheme.keep)
            summaryRow(icon: "trash.slash", label: viewModel.reviewMode == .discardFirst ? "Marked for manual delete" : "Explicit discards", value: "\(viewModel.discardCountTotal)", tint: UITheme.discard)
            summaryRow(icon: "pencil.circle", label: "Edit queue", value: "\(viewModel.editQueueCountTotal)", tint: UITheme.suggested)
            if viewModel.reviewMode == .keepFirst {
                summaryRow(icon: "eye", label: "Review-only keeps", value: "\(viewModel.implicitKeepCountTotal)")
            }
            summaryRow(icon: "externaldrive.badge.minus", label: "Estimated reclaim", value: viewModel.estimatedDiscardSizeLabel)
            summaryRow(icon: "folder.badge.plus", label: "Keep album", value: viewModel.fullySortedAlbumName)
            summaryRow(icon: "folder.badge.minus", label: "Discard album", value: viewModel.manualDeleteAlbumName)

            Text(viewModel.reviewMode == .discardFirst ? "Items are queued for manual review only. This app will not directly delete from your library." : "Only explicit keeps, explicit discards, and edit items are queued. Untouched review-only keeps stay in Photos until you act on them.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(
                viewModel.summaryConfirmationText,
                isOn: $viewModel.deletionArmed
            )
            .toggleStyle(.checkbox)
            .font(.footnote)
        }
    }

    private var folderSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.summaryIntroText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            summaryRow(icon: "checklist", label: "Reviewed groups", value: "\(viewModel.reviewedGroupCount) / \(viewModel.groups.count)")
            summaryRow(icon: "checkmark.circle", label: viewModel.reviewMode == .discardFirst ? "Marked to keep" : "Explicit keeps", value: "\(viewModel.keepCountTotal)", tint: UITheme.keep)
            summaryRow(icon: "trash.slash", label: viewModel.reviewMode == .discardFirst ? "Marked for manual delete" : "Explicit discards", value: "\(viewModel.discardCountTotal)", tint: UITheme.discard)
            summaryRow(icon: "pencil.circle", label: "Edit queue", value: "\(viewModel.editQueueCountTotal)", tint: UITheme.suggested)
            if viewModel.reviewMode == .keepFirst {
                summaryRow(icon: "eye", label: "Review-only keeps", value: "\(viewModel.implicitKeepCountTotal)")
            }
            summaryRow(icon: "externaldrive.badge.minus", label: "Estimated reclaim", value: viewModel.estimatedDiscardSizeLabel)
            summaryRow(icon: "folder", label: "Destination root", value: viewModel.folderCommitDestinationRootPath)
            summaryRow(icon: "folder.badge.plus", label: "Edit queue", value: viewModel.folderDestinationPath(for: .editQueue), tint: UITheme.suggested)
            summaryRow(icon: "folder.badge.minus", label: "Delete queue", value: viewModel.folderDestinationPath(for: .manualDeleteQueue), tint: UITheme.discard)

            if viewModel.moveKeptItemsToKeepFolder || viewModel.folderCommitCount(for: .keep) > 0 {
                summaryRow(icon: "folder.badge.questionmark", label: "Keep folder", value: viewModel.folderDestinationPath(for: .keep), tint: UITheme.keep)
            }

            HStack {
                Button("Reveal Destination Root") {
                    viewModel.revealSourceFolderInFinder()
                }

                Button("Reveal Files to Edit") {
                    viewModel.revealQueueDestinationInFinder(.editQueue)
                }

                Button("Reveal Files to Manually Delete") {
                    viewModel.revealQueueDestinationInFinder(.manualDeleteQueue)
                }
            }
            .buttonStyle(.link)

            folderSampleSection(destination: .editQueue)
            folderSampleSection(destination: .manualDeleteQueue)
            if viewModel.folderCommitCount(for: .keep) > 0 {
                folderSampleSection(destination: .keep)
            }

            Text(viewModel.reviewMode == .discardFirst ? "Only explicitly queued edits and marked discards move by default. Kept files stay in place unless Keep is enabled." : "Only explicit keeps, explicit discards, and edit items move. Untouched review-only keeps stay in place even when Keep is enabled.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(
                viewModel.summaryConfirmationText,
                isOn: $viewModel.deletionArmed
            )
            .toggleStyle(.checkbox)
            .font(.footnote)
        }
    }

    @ViewBuilder
    private func folderSampleSection(destination: FolderCommitDestination) -> some View {
        let count = viewModel.folderCommitCount(for: destination)
        if count > 0 {
            VStack(alignment: .leading, spacing: 6) {
                summaryRow(icon: "arrowshape.right", label: destination.title, value: "\(count)", tint: tint(for: destination))
                ForEach(viewModel.folderCommitSamples(for: destination), id: \.self) { sample in
                    Text(sample)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if viewModel.folderRemainingSampleCount(for: destination) > 0 {
                    Text("+ \(viewModel.folderRemainingSampleCount(for: destination)) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func summaryRow(icon: String, label: String, value: String, tint: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(tint ?? .secondary)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(tint ?? .secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func tint(for destination: FolderCommitDestination) -> Color {
        switch destination {
        case .editQueue:
            return UITheme.suggested
        case .manualDeleteQueue:
            return UITheme.discard
        case .keep:
            return UITheme.keep
        }
    }
}

private struct ReviewGroupView: View {
    @EnvironmentObject private var viewModel: ReviewViewModel
    let group: ReviewGroup
    @State private var hoverPreviewImage: NSImage?
    @State private var hoverPreviewPlayer: AVPlayer?
    @State private var hoverPreviewLoadingVideo = false
    @State private var hoverPreviewVideoErrorMessage: String?

    private let dateFormatter: DateIntervalFormatter = {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private let compactReviewBreakpoint: CGFloat = 760
    private let thumbnailColumnWidth: CGFloat = 220
    private let compactThumbnailCardWidth: CGFloat = 196
    private let regularPreviewMinimumHeight: CGFloat = 560
    private let compactPreviewMinimumHeight: CGFloat = 420

    private var cardHeight: CGFloat {
        112
    }

    private var highlightedAssetID: String? {
        viewModel.highlightedAssetID(in: group)
    }

    private var activePreviewIsVideo: Bool {
        guard let highlightedAssetID else {
            return false
        }
        return viewModel.isVideo(assetID: highlightedAssetID)
    }

    private var highlightedMediaBadges: [String] {
        guard let highlightedAssetID else {
            return []
        }
        return viewModel.mediaBadges(for: highlightedAssetID)
    }

    private var highlightedIsKept: Bool {
        guard let highlightedAssetID else {
            return true
        }
        return viewModel.isKept(assetID: highlightedAssetID, in: group)
    }

    private var highlightedStatusLabel: String {
        guard let highlightedAssetID else {
            return "KEEP"
        }
        return viewModel.reviewStatusLabel(assetID: highlightedAssetID, in: group)
    }

    private var highlightedStatusColor: Color {
        guard let highlightedAssetID else {
            return UITheme.keep
        }
        if viewModel.isQueuedForEdit(assetID: highlightedAssetID) {
            return UITheme.suggested
        }
        if viewModel.isExplicitKeep(assetID: highlightedAssetID, in: group) {
            return UITheme.keep
        }
        if viewModel.isImplicitKeep(assetID: highlightedAssetID, in: group) {
            return UITheme.suggested
        }
        return UITheme.discard
    }

    private var groupDateLabel: String {
        switch (group.startDate, group.endDate) {
        case let (.some(start), .some(end)):
            return dateFormatter.string(from: start, to: end)
        case let (.some(start), nil):
            return dateFormatter.string(from: start, to: start)
        case let (nil, .some(end)):
            return dateFormatter.string(from: end, to: end)
        case (nil, nil):
            return "Date unavailable"
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let isCompactLayout = proxy.size.width < compactReviewBreakpoint

            Group {
                if isCompactLayout {
                    ScrollView {
                        reviewContent(isCompactLayout: true)
                    }
                } else {
                    reviewContent(isCompactLayout: false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .animation(.spring(response: 0.26, dampingFraction: 0.84), value: viewModel.keepCountTotalReviewed)
        .animation(.spring(response: 0.26, dampingFraction: 0.84), value: viewModel.discardCountTotalReviewed)
        .animation(.easeInOut(duration: 0.18), value: viewModel.reviewedGroupCount)
        .onAppear {
            viewModel.ensureHighlightedAsset(in: group)
            viewModel.markGroupReviewed(group)
        }
        .task(id: highlightedAssetID) {
            await loadPreview(for: highlightedAssetID)
        }
        .onChange(of: group.id) { _, _ in
            hoverPreviewPlayer?.pause()
            hoverPreviewPlayer = nil
            hoverPreviewLoadingVideo = false
            hoverPreviewVideoErrorMessage = nil
            viewModel.ensureHighlightedAsset(in: group)
            viewModel.markGroupReviewed(group)

            let previewCandidates = Array(group.itemIDs.prefix(3))
            Task {
                for assetID in previewCandidates {
                    _ = await viewModel.thumbnail(
                        for: assetID,
                        side: 900,
                        contentMode: .aspectFit,
                        deliveryMode: .opportunistic
                    )
                }
            }
        }
        .onChange(of: viewModel.autoplayPreviewVideos) { _, _ in
            updateVideoPlaybackState()
        }
        .onDisappear {
            hoverPreviewPlayer?.pause()
            hoverPreviewPlayer = nil
            hoverPreviewVideoErrorMessage = nil
        }
    }

    private func loadPreview(for assetID: String?) async {
        guard let assetID else {
            hoverPreviewImage = nil
            hoverPreviewPlayer?.pause()
            hoverPreviewPlayer = nil
            hoverPreviewLoadingVideo = false
            hoverPreviewVideoErrorMessage = nil
            return
        }

        let activeID = assetID

        hoverPreviewPlayer?.pause()
        hoverPreviewPlayer = nil
        hoverPreviewLoadingVideo = false
        hoverPreviewVideoErrorMessage = nil

        if viewModel.isVideo(assetID: activeID) {
            hoverPreviewImage = nil
            hoverPreviewLoadingVideo = true

            if let quickPreview = await viewModel.thumbnail(
                for: activeID,
                side: 900,
                contentMode: .aspectFit,
                deliveryMode: .opportunistic
            ), highlightedAssetID == activeID {
                hoverPreviewImage = quickPreview
            }

            let previewResult = await viewModel.previewPlayerResult(for: activeID)
            guard highlightedAssetID == activeID else {
                return
            }

            switch previewResult {
            case .ready(let player):
                hoverPreviewPlayer = player
                hoverPreviewLoadingVideo = false
                hoverPreviewVideoErrorMessage = nil
                updateVideoPlaybackState()

            case .unavailable(let message):
                hoverPreviewLoadingVideo = false
                hoverPreviewVideoErrorMessage = message
            }

            return
        }

        hoverPreviewImage = nil
        hoverPreviewVideoErrorMessage = nil

        if let quickPreview = await viewModel.thumbnail(
            for: activeID,
            side: 900,
            contentMode: .aspectFit,
            deliveryMode: .opportunistic
        ), highlightedAssetID == activeID {
            hoverPreviewImage = quickPreview
        }

        if let highQualityPreview = await viewModel.thumbnail(
            for: activeID,
            side: 2_000,
            contentMode: .aspectFit,
            deliveryMode: .highQualityFormat
        ), highlightedAssetID == activeID {
            hoverPreviewImage = highQualityPreview
        }
    }

    private func updateVideoPlaybackState() {
        guard let player = hoverPreviewPlayer else {
            return
        }

        player.seek(to: .zero)
        if viewModel.autoplayPreviewVideos {
            player.play()
        } else {
            player.pause()
        }
    }

    private func scrollToHighlighted(_ assetID: String?, with proxy: ScrollViewProxy) {
        guard let assetID else {
            return
        }

        withAnimation(.easeInOut(duration: 0.12)) {
            proxy.scrollTo(assetID, anchor: .center)
        }
    }

    private func reviewContent(isCompactLayout: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ReviewHUDBar(
                reviewMode: viewModel.reviewMode,
                groupIndex: viewModel.currentGroupIndex + 1,
                groupCount: viewModel.groups.count,
                reviewedCount: viewModel.reviewedGroupCount,
                keptCount: viewModel.keepCountTotalReviewed,
                discardCount: viewModel.discardCountTotalReviewed,
                totalCount: viewModel.totalAssetCountInBatch,
                estimatedDiscardSummary: viewModel.estimatedDiscardSummary
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Group \(viewModel.currentGroupIndex + 1) of \(viewModel.groups.count)")
                    .font(.title2.bold())

                Text(groupDateLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(viewModel.isGroupReviewed(group) ? "Reviewed" : "Unreviewed")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (viewModel.isGroupReviewed(group) ? UITheme.keep : UITheme.suggested)
                            .opacity(0.92),
                        in: Capsule()
                    )
                    .foregroundStyle(.white)

                Text("Review pane shortcuts: ↑/↓ highlight, ` keep/discard, E queue edit, ←/→ change group.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(viewModel.reviewGuidanceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let editQueueMessage = viewModel.editQueueMessage {
                    Label(editQueueMessage, systemImage: "pencil.circle.fill")
                        .font(.caption)
                        .foregroundStyle(UITheme.suggested)
                }
            }

            if isCompactLayout {
                VStack(alignment: .leading, spacing: 16) {
                    compactThumbnailRail
                    previewPanel(minimumPreviewHeight: compactPreviewMinimumHeight)
                }
            } else {
                HStack(alignment: .top, spacing: 20) {
                    regularThumbnailColumn

                    previewPanel(minimumPreviewHeight: regularPreviewMinimumHeight)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            HStack {
                Spacer()

                Button {
                    viewModel.confirmQueueMarkedAssetsForManualDelete()
                } label: {
                    if viewModel.isDeleting {
                        Label(viewModel.selectedSourceKind == .photos ? "Queueing..." : "Committing...", systemImage: "hourglass")
                    } else {
                        Text(viewModel.selectedSourceKind == .photos ? "Open Summary and Queue" : "Open Summary and Commit")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canOpenSummary)
            }
            .padding(.top, 4)
        }
        .padding(24)
    }

    private var regularThumbnailColumn: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(group.itemIDs, id: \.self) { assetID in
                        assetCard(for: assetID)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 4)
            }
            .onAppear {
                scrollToHighlighted(highlightedAssetID, with: proxy)
            }
            .onChange(of: highlightedAssetID) { _, newID in
                scrollToHighlighted(newID, with: proxy)
            }
        }
        .frame(minWidth: thumbnailColumnWidth, idealWidth: thumbnailColumnWidth, maxWidth: thumbnailColumnWidth)
        .frame(maxHeight: .infinity)
    }

    private var compactThumbnailRail: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(group.itemIDs, id: \.self) { assetID in
                        assetCard(for: assetID)
                            .frame(width: compactThumbnailCardWidth)
                    }
                }
                .padding(.vertical, 4)
            }
            .onAppear {
                scrollToHighlighted(highlightedAssetID, with: proxy)
            }
            .onChange(of: highlightedAssetID) { _, newID in
                scrollToHighlighted(newID, with: proxy)
            }
        }
    }

    private func assetCard(for assetID: String) -> some View {
        AssetCardView(
            group: group,
            assetID: assetID,
            isKept: viewModel.isKept(assetID: assetID, in: group),
            isHighlighted: viewModel.isHighlighted(assetID: assetID, in: group),
            imageHeight: cardHeight,
            onSelected: {
                viewModel.setHighlighted(assetID: assetID, in: group)
            }
        )
        .environmentObject(viewModel)
        .id(assetID)
    }

    private func previewPanel(minimumPreviewHeight: CGFloat) -> some View {
        HoverZoomPanel(
            image: hoverPreviewImage,
            player: hoverPreviewPlayer,
            isVideo: activePreviewIsVideo,
            isLoadingVideo: hoverPreviewLoadingVideo,
            videoPreviewErrorMessage: hoverPreviewVideoErrorMessage,
            autoplayEnabled: viewModel.autoplayPreviewVideos,
            mediaBadges: highlightedMediaBadges,
            statusLabel: highlightedStatusLabel,
            statusColor: highlightedStatusColor,
            minimumPreviewHeight: minimumPreviewHeight,
            canOpenFocusedItem: viewModel.canOpenFocusedItem,
            onOpenFocusedItem: viewModel.openFocusedItem
        )
        .frame(maxWidth: .infinity)
    }
}

private struct ReviewHUDBar: View {
    let reviewMode: ReviewMode
    let groupIndex: Int
    let groupCount: Int
    let reviewedCount: Int
    let keptCount: Int
    let discardCount: Int
    let totalCount: Int
    let estimatedDiscardSummary: String

    private var keepFraction: CGFloat {
        guard totalCount > 0 else { return 0 }
        return min(1, max(0, CGFloat(keptCount) / CGFloat(totalCount)))
    }

    private var discardFraction: CGFloat {
        guard totalCount > 0 else { return 0 }
        return min(1, max(0, CGFloat(discardCount) / CGFloat(totalCount)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text(reviewMode.title)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background((reviewMode == .discardFirst ? UITheme.discard : UITheme.keep).opacity(0.9), in: Capsule())
                    .foregroundStyle(.white)

                Spacer()

                Text("Group \(groupIndex) of \(groupCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            GeometryReader { proxy in
                let totalWidth = proxy.size.width
                let reviewedFraction = keepFraction + discardFraction
                let normalize = reviewedFraction > 1 ? reviewedFraction : 1
                let keepWidth = totalWidth * (keepFraction / normalize)
                let discardWidth = totalWidth * (discardFraction / normalize)
                let unreviewedWidth = max(0, totalWidth - keepWidth - discardWidth)

                HStack(spacing: 0) {
                    Rectangle()
                        .fill(UITheme.keep)
                        .frame(width: keepWidth)
                    Rectangle()
                        .fill(UITheme.discard)
                        .frame(width: discardWidth)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.22))
                        .frame(width: unreviewedWidth)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.black.opacity(0.12), lineWidth: 0.8)
                )
            }
            .frame(height: 12)
            .animation(.easeInOut(duration: 0.20), value: keptCount)
            .animation(.easeInOut(duration: 0.20), value: discardCount)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    metricRow
                    Spacer()
                    estimatedDiscardText
                }

                VStack(alignment: .leading, spacing: 8) {
                    metricRow
                    estimatedDiscardText
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
    }

    private func metric(title: String, value: Int, suffix: String = "", tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 0) {
                Text("\(value)")
                    .contentTransition(.numericText())
                Text(suffix)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
        }
    }

    private var metricRow: some View {
        HStack(spacing: 14) {
            metric(title: reviewMode == .discardFirst ? "Keep" : "Kept In Review", value: keptCount, tint: UITheme.keep)
            metric(title: reviewMode == .discardFirst ? "Discard" : "Discarded In Review", value: discardCount, tint: UITheme.discard)
            metric(title: "Reviewed", value: reviewedCount, suffix: "/\(groupCount)", tint: UITheme.suggested)
        }
    }

    private var estimatedDiscardText: some View {
        Text(estimatedDiscardSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct HoverZoomPanel: View {
    let image: NSImage?
    let player: AVPlayer?
    let isVideo: Bool
    let isLoadingVideo: Bool
    let videoPreviewErrorMessage: String?
    let autoplayEnabled: Bool
    let mediaBadges: [String]
    let statusLabel: String
    let statusColor: Color
    let minimumPreviewHeight: CGFloat
    let canOpenFocusedItem: Bool
    let onOpenFocusedItem: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if canOpenFocusedItem {
                    Text("Double-click to open")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.08))

                if let player {
                    AppKitVideoPlayerView(player: player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(10)
                        .transition(.opacity)
                        .overlay(alignment: .bottomLeading) {
                            if !autoplayEnabled {
                                Text("Autoplay off. Press play.")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .padding(18)
                            }
                        }
                } else if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(10)
                        .id(ObjectIdentifier(image))
                        .transition(.opacity)
                        .overlay(alignment: .bottomLeading) {
                            if let videoPreviewErrorMessage, isVideo {
                                Text(videoPreviewErrorMessage)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .padding(18)
                            }
                        }
                } else if isLoadingVideo {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Loading video preview...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                } else if isVideo {
                    Text(videoPreviewErrorMessage ?? "Video preview unavailable for this item.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                } else {
                    Text("Select or hover a thumbnail to preview it here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.20), value: previewStateKey)
            .overlay(alignment: .top) {
                if image != nil || player != nil || isLoadingVideo || isVideo {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top) {
                            mediaBadgeStrip
                            Spacer(minLength: 12)
                            statusBadge
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            mediaBadgeStrip
                                .frame(maxWidth: .infinity, alignment: .leading)
                            statusBadge
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(18)
                }
            }
            .frame(maxWidth: .infinity, minHeight: minimumPreviewHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture(count: 2) {
                guard canOpenFocusedItem else { return }
                onOpenFocusedItem()
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    image != nil || player != nil || isLoadingVideo || isVideo
                        ? statusColor.opacity(0.9)
                        : Color.secondary.opacity(0.35),
                    lineWidth: image != nil || player != nil || isLoadingVideo || isVideo ? 3 : 1
                )
        )
    }

    private var previewStateKey: Int {
        if player != nil {
            return 1
        }
        if let image {
            return ObjectIdentifier(image).hashValue
        }
        if isLoadingVideo {
            return 2
        }
        if videoPreviewErrorMessage != nil {
            return 4
        }
        if isVideo {
            return 3
        }
        return 0
    }

    @ViewBuilder
    private var mediaBadgeStrip: some View {
        if mediaBadges.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 4) {
                ForEach(mediaBadges, id: \.self) { badge in
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(UITheme.mediaBadgeBackground)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        Text(statusLabel)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.9))
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }
}

private struct AppKitVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView(frame: .zero)
        playerView.videoGravity = .resizeAspect
        playerView.controlsStyle = .floating
        playerView.updatesNowPlayingInfoCenter = false
        playerView.player = player
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player = nil
    }
}

private struct ReviewKeyBindingHost: View {
    let previousGroup: () -> Void
    let nextGroup: () -> Void
    let previousItem: () -> Void
    let nextItem: () -> Void
    let toggleKeepDiscard: () -> Void
    let queueForEdit: () -> Void

    var body: some View {
        VStack {
            shortcutButton("Previous Group", action: previousGroup)
                .keyboardShortcut(.leftArrow, modifiers: [])
            shortcutButton("Next Group", action: nextGroup)
                .keyboardShortcut(.rightArrow, modifiers: [])
            shortcutButton("Previous Item", action: previousItem)
                .keyboardShortcut(.upArrow, modifiers: [])
            shortcutButton("Next Item", action: nextItem)
                .keyboardShortcut(.downArrow, modifiers: [])
            shortcutButton("Toggle Keep Or Discard", action: toggleKeepDiscard)
                .keyboardShortcut("`", modifiers: [])
            shortcutButton("Queue Highlighted For Edit", action: queueForEdit)
                .keyboardShortcut("e", modifiers: [])
        }
        .opacity(0.001)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func shortcutButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
    }
}
