import AppKit
import AVFoundation
import AVKit
import Photos
import PhotosSortCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var viewModel: ReviewViewModel
    @Environment(\.scenePhase) private var scenePhase
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
                .background(
                    ReviewKeyboardMonitor(
                        isEnabled: isReviewShortcutContextAvailable,
                        handleEvent: handleReviewKeyEvent
                    )
                )
                .contentShape(Rectangle())
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await viewModel.appDidBecomeActive() }
            }
        }
        .sheet(isPresented: $viewModel.showDeleteConfirmation) {
            SessionSummarySheet(isPresented: $viewModel.showDeleteConfirmation)
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $viewModel.showPhotoQueue) {
            PhotoPendingQueueSheet(isPresented: $viewModel.showPhotoQueue)
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
            Text(viewModel.selectedSourceKind == .photos
                ? "Changing review mode clears the displayed scan and requires a fresh scan. Already staged Photos choices remain saved on this Mac, and completed groups keep their original staged defaults."
                : "Changing review mode clears the current folder review session and requires a fresh scan. Existing folder selections will be lost.")
        }
        .alert("Change Source?", isPresented: $viewModel.showSourceResetConfirmation) {
            Button("Cancel", role: .cancel) {
                viewModel.cancelSourceKindChange()
            }
            Button("Change Source And Reset", role: .destructive) {
                viewModel.confirmSourceKindChange()
            }
        } message: {
            Text(viewModel.selectedSourceKind == .photos
                ? "Changing the source clears the displayed Photos scan. Staged Photos choices remain saved on this Mac."
                : "Changing the source clears the current folder review session and requires a fresh scan. Existing folder selections will be lost.")
        }
        .alert("Start Scan From Beginning?", isPresented: $viewModel.showBatchRestartConfirmation) {
            Button("Cancel", role: .cancel) {
                viewModel.cancelBatchRestart()
            }
            Button("Start Over", role: .destructive) {
                viewModel.confirmBatchRestart()
            }
        } message: {
            Text(viewModel.batchRestartConfirmationMessage)
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
                    .disabled(viewModel.isScanning || viewModel.isPreparingScan)
                }
            }

            ToolbarItem(placement: .principal) {
                Label(viewModel.currentSourceSummary, systemImage: viewModel.selectedSourceKind == .photos ? "photo.stack" : "folder")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if viewModel.selectedSourceKind == .photos || viewModel.pendingPhotoCount > 0 {
                    Button {
                        viewModel.openPhotoPendingQueue()
                    } label: {
                        Label(
                            "Photos Queue \(viewModel.pendingPhotoCount)",
                            systemImage: viewModel.photoLibraryNeedsRecheck ? "arrow.triangle.2.circlepath" : "tray.full"
                        )
                    }
                    .disabled(viewModel.pendingPhotoCount == 0)
                }
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

                Button(
                    viewModel.isPreparingScan ? "Preparing..." : (viewModel.isScanning ? "Stop Scan" : viewModel.primaryScanActionTitle),
                    systemImage: viewModel.isScanning ? "stop.fill" : "magnifyingglass"
                ) {
                    if viewModel.isScanning || viewModel.isPreparingScan {
                        viewModel.stopScan()
                    } else if viewModel.canScanNextBatch {
                        viewModel.requestNextBatch()
                    } else {
                        viewModel.requestScan()
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(viewModel.isScanning || viewModel.isPreparingScan ? false : !viewModel.canInitiateScan)

                Button(viewModel.selectedSourceKind == .photos ? "Commit All…" : "Commit Summary", systemImage: "checklist") {
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
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "Photo Access Needed",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text(PhotoAuthorizationSupport.accessDescription(for: viewModel.authorizationStatus))
                    )

                    PhotoAccessActionsView(viewModel: viewModel, prominentSettingsButton: true)
                }
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
                    .buttonStyle(.glassProminent)
                }
            } else if let group = viewModel.currentGroup {
                ReviewGroupView(group: group)
                    .environmentObject(viewModel)
                    .id(group.id)
            } else if viewModel.selectedSourceKind == .photos, !viewModel.groups.isEmpty,
                      viewModel.currentGroupIndex >= viewModel.groups.count {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "Review Pass Complete",
                        systemImage: "checkmark.circle",
                        description: Text("You reached the end of this oldest-first group pass. Your staged choices remain on this device until you commit them to Photos.")
                    )
                    HStack {
                        Button("Previous Group", systemImage: "chevron.left") {
                            viewModel.previousGroup()
                        }
                        Button(viewModel.primaryScanActionTitle, systemImage: "arrow.clockwise") {
                            if viewModel.canScanNextBatch { viewModel.requestNextBatch() }
                            else { viewModel.requestScan() }
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(viewModel.isScanning || viewModel.isPreparingScan || !viewModel.canInitiateScan)
                    }
                }
            } else {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "No Group Selected",
                        systemImage: viewModel.selectedSourceKind == .folder ? "folder.badge.questionmark" : "photo.stack",
                        description: Text(viewModel.selectedSourceKind == .folder
                            ? "Run a scan to load oldest-first media groups, or open the selected folder in Finder first."
                            : "Run a scan to load oldest-first unsorted Photos groups.")
                    )

                    if viewModel.selectedSourceKind == .folder {
                        Button("Open Selected Folder") {
                            viewModel.openSelectedFolder()
                        }
                        .disabled(!viewModel.canRevealSourceFolder)
                    }

                    Button(viewModel.primaryScanActionTitle) {
                        if viewModel.canScanNextBatch {
                            viewModel.requestNextBatch()
                        } else {
                            viewModel.requestScan()
                        }
                    }
                    .disabled(viewModel.isScanning || viewModel.isPreparingScan || !viewModel.canInitiateScan)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var isReviewShortcutContextAvailable: Bool {
        viewModel.currentGroup != nil
            && !viewModel.showDeleteConfirmation
            && !viewModel.showReviewModeResetConfirmation
            && !viewModel.showSourceResetConfirmation
    }

    private func handleReviewKeyEvent(_ event: NSEvent) -> Bool {
        guard isReviewShortcutContextAvailable else {
            return false
        }

        guard let action = ReviewKeyboardAction.resolve(event: event) else {
            return false
        }

        switch action {
        case .previousGroup:
            guard viewModel.hasPreviousGroup else { return false }
            viewModel.previousGroup()
        case .nextGroup:
            guard viewModel.hasNextGroup else { return false }
            viewModel.nextGroup()
        case .previousItem:
            guard viewModel.hasHighlightInCurrentGroup else { return false }
            viewModel.highlightPreviousAssetInCurrentGroup()
        case .nextItem:
            guard viewModel.hasHighlightInCurrentGroup else { return false }
            viewModel.highlightNextAssetInCurrentGroup()
        case .toggleKeepDiscard:
            guard viewModel.hasHighlightInCurrentGroup else { return false }
            viewModel.toggleHighlightedAssetInCurrentGroup()
        case .queueForEdit:
            guard viewModel.hasHighlightInCurrentGroup, !viewModel.isQueuingForEdit else {
                return false
            }
            viewModel.queueHighlightedAssetForEditingInCurrentGroup()
        }

        return true
    }
}

private struct ReviewKeyboardMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let handleEvent: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, handleEvent: handleEvent)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView)
        context.coordinator.isEnabled = isEnabled
        context.coordinator.handleEvent = handleEvent
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var isEnabled: Bool
        var handleEvent: (NSEvent) -> Bool

        private weak var view: NSView?
        private var monitor: Any?

        init(isEnabled: Bool, handleEvent: @escaping (NSEvent) -> Bool) {
            self.isEnabled = isEnabled
            self.handleEvent = handleEvent
        }

        func attach(to view: NSView) {
            self.view = view
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard self.isEnabled else { return event }
                return self.handleEvent(event) ? nil : event
            }
        }

        func detach() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            view = nil
        }

        deinit {
            detach()
        }
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
                        Picker("Source type", selection: Binding(
                            get: { viewModel.selectedSourceKind },
                            set: { viewModel.requestSourceKindChange($0) }
                        )) {
                            ForEach(ReviewSourceKind.allCases) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(viewModel.isScanning || viewModel.isPreparingScan)

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

                        HStack(spacing: 8) {
                            Toggle("Stop after", isOn: $viewModel.groupLimitEnabled)
                                .disabled(viewModel.isScanning || viewModel.isPreparingScan)
                            TextField("Group limit", value: $viewModel.groupLimit, format: .number)
                                .frame(width: 64)
                                .multilineTextAlignment(.trailing)
                                .accessibilityLabel("Maximum groups")
                                .disabled(!viewModel.groupLimitEnabled || viewModel.isScanning || viewModel.isPreparingScan)
                            Stepper("Maximum groups", value: $viewModel.groupLimit, in: 1...10_000)
                                .labelsHidden()
                                .disabled(!viewModel.groupLimitEnabled || viewModel.isScanning || viewModel.isPreparingScan)
                            Text("groups")
                                .foregroundStyle(.secondary)
                        }

                        Label(viewModel.reviewModeStatusText, systemImage: "hand.raised")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(viewModel.reviewMode == .discardFirst ? UITheme.discard : UITheme.keep)

                        Text(viewModel.reviewGuidanceText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Button {
                            if viewModel.canScanNextBatch {
                                viewModel.requestNextBatch()
                            } else {
                                viewModel.requestScan()
                            }
                        } label: {
                            Label(
                                viewModel.isPreparingScan ? "Preparing..." : (viewModel.isScanning ? "Scanning..." : viewModel.primaryScanActionTitle),
                                systemImage: "magnifyingglass"
                            )
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(viewModel.isScanning || viewModel.isPreparingScan || !viewModel.canInitiateScan)

                        if viewModel.isScanning {
                            Button(role: .destructive) {
                                viewModel.stopScan()
                            } label: {
                                Label("Stop Scan", systemImage: "stop.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
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
                        if viewModel.selectedSourceKind == .photos {
                            LabeledContent("Staged choices", value: "\(viewModel.pendingPhotoCount)")
                        } else {
                            LabeledContent("Estimated reclaim", value: viewModel.estimatedDiscardSizeLabel)
                        }

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

            PhotoAccessActionsView(viewModel: viewModel)
        }
    }

    private var folderSelectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Choose Folder...") {
                viewModel.changeSourceFolder()
            }
            .buttonStyle(.glassProminent)
            .disabled(viewModel.isScanning || viewModel.isPreparingScan)

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

private struct PhotoAccessActionsView: View {
    @ObservedObject var viewModel: ReviewViewModel
    var prominentSettingsButton = false

    var body: some View {
        switch viewModel.authorizationStatus {
        case .notDetermined:
            Button("Request Photos Access") {
                Task {
                    await viewModel.requestPhotoAccess()
                }
            }
            .buttonStyle(.glassProminent)

        case .denied:
            HStack {
                if prominentSettingsButton {
                    Button("Open Photos Privacy Settings") {
                        viewModel.openPhotoPrivacySettings()
                    }
                    .buttonStyle(.glassProminent)
                } else {
                    Button("Open Photos Privacy Settings") {
                        viewModel.openPhotoPrivacySettings()
                    }
                    .buttonStyle(.glass)
                }

                Button("Refresh Access") {
                    Task {
                        await viewModel.refreshPhotoAuthorizationStatus()
                    }
                }
            }

        case .restricted:
            Button("Refresh Access") {
                Task {
                    await viewModel.refreshPhotoAuthorizationStatus()
                }
            }

        default:
            EmptyView()
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
                        if viewModel.selectedSourceKind == .photos {
                            LabeledContent("Staged choices", value: "\(viewModel.pendingPhotoCount)")
                        } else {
                            LabeledContent("Estimated reclaim", value: viewModel.estimatedDiscardSizeLabel)
                        }
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
        let hasCommittableWork = viewModel.selectedSourceKind == .photos
            ? viewModel.photoCommitEligibleCount > 0
            : viewModel.hasPendingCommitActions
        return (hasCommittableWork || viewModel.canFinalizeBatchWithoutActions)
            && !viewModel.isDeleting
            && viewModel.deletionArmed
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

            if viewModel.selectedSourceKind == .folder,
               let progress = viewModel.folderCommitProgress,
               viewModel.isDeleting {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress.fractionCompleted)
                        .accessibilityLabel("Folder commit progress")
                        .accessibilityValue("\(progress.movedCount) moved, \(progress.processedCount) of \(progress.totalCount) processed")
                    Text(progress.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            HStack {
                if viewModel.selectedSourceKind == .folder, viewModel.isDeleting {
                    Button(viewModel.isCancellingFolderCommit ? "Stopping..." : "Cancel Commit", role: .cancel) {
                        viewModel.cancelFolderCommit()
                    }
                    .disabled(viewModel.isCancellingFolderCommit)
                } else {
                    Button("Cancel", role: .cancel) {
                        viewModel.deletionArmed = false
                        isPresented = false
                    }
                }

                Spacer()

                Button {
                    viewModel.queueMarkedAssetsForManualDelete()
                } label: {
                    if viewModel.isDeleting {
                        Label(viewModel.selectedSourceKind == .photos ? "Committing..." : "Moving...", systemImage: "hourglass")
                    } else {
                        Text(
                            viewModel.canFinalizeBatchWithoutActions
                                ? "Complete Batch"
                                : (viewModel.selectedSourceKind == .photos ? "Commit All" : "Commit Folder Queues")
                        )
                    }
                }
                .buttonStyle(.glassProminent)
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
            summaryRow(icon: "tray.full", label: "Commit-ready", value: "\(viewModel.photoCommitEligibleCount)")
            if viewModel.pendingPhotoConflictCount > 0 || viewModel.pendingPhotoUnavailableCount > 0 {
                summaryRow(
                    icon: "exclamationmark.triangle",
                    label: "Needs review",
                    value: "\(viewModel.pendingPhotoConflictCount) conflict · \(viewModel.pendingPhotoUnavailableCount) unavailable",
                    tint: .orange
                )
            }
            summaryRow(icon: "folder.badge.plus", label: "Keep album", value: viewModel.fullySortedAlbumName)
            summaryRow(icon: "folder.badge.minus", label: "Discard album", value: viewModel.manualDeleteAlbumName)

            Text("Commit All adds each staged classification to its bound Photos album. Nothing is deleted. Conflicts and unavailable items remain in the local queue for review.")
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

private struct PhotoPendingQueueSheet: View {
    @EnvironmentObject private var viewModel: ReviewViewModel
    @Binding var isPresented: Bool

    private var pendingRows: [PendingReviewItem] { viewModel.pendingPhotoItems }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Staged Photos Choices")
                        .font(.title3.bold())
                    Text("Saved on this Mac · \(viewModel.pendingPhotoCount) item(s)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(viewModel.isRecheckingPhotoQueue ? "Rechecking..." : "Recheck Photos", systemImage: "arrow.clockwise") {
                    Task { await viewModel.recheckPhotoQueue() }
                }
                .disabled(viewModel.isRecheckingPhotoQueue || viewModel.isDeleting || viewModel.isScanning || viewModel.isPreparingScan)
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }

            if viewModel.pendingPhotoConflictCount > 0 || viewModel.pendingPhotoUnavailableCount > 0 {
                Label(
                    "\(viewModel.pendingPhotoConflictCount) conflict(s), \(viewModel.pendingPhotoUnavailableCount) unavailable. These remain staged until you revise them or Photos confirms them.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(pendingRows, id: \PendingReviewItem.assetID) { (item: PendingReviewItem) in
                    VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(viewModel.pendingPhotoTitle(for: item.assetID))
                            .font(.headline)
                            .lineLimit(1)
                        Spacer()
                        Text(item.status.rawValue.capitalized)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(item.status == .pending ? Color.secondary : Color.orange)
                    }
                    Text("\(item.decision.rawValue.capitalized) · \(item.origin == .explicit ? "Explicit choice" : "Staged mode default")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        queueDecisionButton(.keep, item: item)
                        queueDecisionButton(.discard, item: item)
                        queueDecisionButton(.edit, item: item)
                        Spacer(minLength: 0)
                        Text("\(item.assetID.suffix(10))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                        }
                        .padding(.vertical, 5)
                    }
                    .padding(.horizontal, 2)
                }
            }
            .frame(maxHeight: .infinity)

            HStack {
                Text(viewModel.selectedSourceKind == .photos
                    ? "Commit All adds choices to their bound Photos albums. It never deletes photos."
                    : "Switch to Photos mode to commit these staged choices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Commit All…") {
                    isPresented = false
                    Task {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        viewModel.confirmQueueMarkedAssetsForManualDelete()
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(viewModel.selectedSourceKind != .photos || viewModel.photoCommitEligibleCount == 0)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 460)
        .onAppear { viewModel.reloadPhotoPendingItems() }
    }

    private func queueDecisionButton(_ decision: ReviewDecision, item: PendingReviewItem) -> some View {
        Button(decision.rawValue.capitalized) {
            viewModel.setPendingPhotoDecision(decision, for: item.assetID)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(item.decision == decision ? .accentColor : .secondary)
        .accessibilityLabel("Set \(decision.rawValue) for \(viewModel.pendingPhotoTitle(for: item.assetID))")
    }
}

private struct ReviewGroupView: View {
    @EnvironmentObject private var viewModel: ReviewViewModel
    let group: ReviewGroup

    private struct PreviewRequest: Hashable {
        let groupID: UUID
        let assetID: String?
    }

    @State private var hoverPreviewImage: NSImage?
    @State private var hoverPreviewPlayer: AVPlayer?
    @State private var hoverPreviewResourceLease: AnyObject?
    @State private var hoverPreviewLoadingVideo = false
    @State private var hoverPreviewVideoErrorMessage: String?
    @State private var loadedPreviewRequest: PreviewRequest?
    @State private var inspectionRequest: PhotosInspectionRequest?

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

    private var comparablePhotoAssetIDs: [String] {
        guard viewModel.selectedSourceKind == .photos else { return [] }
        return group.itemIDs.filter { viewModel.isPhotosAsset(assetID: $0) && !viewModel.isVideo(assetID: $0) }
    }

    private var previewRequest: PreviewRequest {
        PreviewRequest(groupID: group.id, assetID: highlightedAssetID)
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
        .task(id: previewRequest) {
            await loadPreview(for: previewRequest)
        }
        .onChange(of: group.id) { _, _ in
            resetPreviewState()
            viewModel.ensureHighlightedAsset(in: group)
            viewModel.markGroupReviewed(group)
        }
        .onChange(of: viewModel.autoplayPreviewVideos) { _, _ in
            updateVideoPlaybackState()
        }
        .onDisappear {
            resetPreviewState()
        }
        .sheet(item: $inspectionRequest) { request in
            PhotosInspectionWorkspace(request: request)
                .environmentObject(viewModel)
        }
    }

    private func loadPreview(for request: PreviewRequest) async {
        resetPreviewState()

        guard let activeID = request.assetID else {
            return
        }

        if viewModel.isVideo(assetID: activeID) {
            hoverPreviewLoadingVideo = true

            if let quickPreview = await viewModel.thumbnail(
                for: activeID,
                side: 900,
                contentMode: .aspectFit,
                deliveryMode: .opportunistic
            ), isCurrentPreview(request) {
                hoverPreviewImage = quickPreview
                loadedPreviewRequest = request
            }

            // Do not start an expensive Photos video request for a group the user
            // has already navigated away from.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard isCurrentPreview(request) else {
                return
            }

            let previewResult = await viewModel.previewPlayerResult(for: activeID)
            guard isCurrentPreview(request) else {
                return
            }

            switch previewResult {
            case .ready(let player, let retainedResource):
                hoverPreviewPlayer = player
                hoverPreviewResourceLease = retainedResource
                loadedPreviewRequest = request
                hoverPreviewLoadingVideo = false
                hoverPreviewVideoErrorMessage = nil
                updateVideoPlaybackState()

            case .unavailable(let message):
                hoverPreviewLoadingVideo = false
                hoverPreviewVideoErrorMessage = message
            }

            return
        }

        if let quickPreview = await viewModel.thumbnail(
            for: activeID,
            side: 900,
            contentMode: .aspectFit,
            deliveryMode: .opportunistic
        ), isCurrentPreview(request) {
            hoverPreviewImage = quickPreview
            loadedPreviewRequest = request
        }

        if let highQualityPreview = await viewModel.thumbnail(
            for: activeID,
            side: 2_000,
            contentMode: .aspectFit,
            deliveryMode: .highQualityFormat
        ), isCurrentPreview(request) {
            hoverPreviewImage = highQualityPreview
            loadedPreviewRequest = request
        }
    }

    private func isCurrentPreview(_ request: PreviewRequest) -> Bool {
        !Task.isCancelled && previewRequest == request
    }

    private func resetPreviewState() {
        hoverPreviewPlayer?.pause()
        hoverPreviewPlayer = nil
        hoverPreviewResourceLease = nil
        hoverPreviewImage = nil
        hoverPreviewLoadingVideo = false
        hoverPreviewVideoErrorMessage = nil
        loadedPreviewRequest = nil
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

                if viewModel.selectedSourceKind == .photos {
                    HStack(spacing: 8) {
                        Button("Inspect Selected Media", systemImage: "arrow.up.right.square") {
                            presentInspection()
                        }
                        .disabled(highlightedAssetID.map { !viewModel.isPhotosAsset(assetID: $0) } ?? true)

                        Button("Compare Two Photos", systemImage: "rectangle.split.2x1") {
                            presentComparison()
                        }
                        .disabled(comparablePhotoAssetIDs.count < 2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

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

            HStack(spacing: 10) {
                if viewModel.selectedSourceKind == .photos {
                    Button("Skip Unresolved") {
                        viewModel.skipCurrentGroup()
                    }
                    .help("Move past this group without staging defaults for untouched items.")
                    Button(viewModel.currentGroupIndex == viewModel.groups.count - 1 ? "Stage & Finish" : "Stage & Next") {
                        viewModel.nextGroup()
                    }
                    .buttonStyle(.bordered)
                    .help("Complete this group using the current review mode for untouched items, then continue.")
                }

                Spacer()

                Button {
                    viewModel.confirmQueueMarkedAssetsForManualDelete()
                } label: {
                    if viewModel.isDeleting {
                        Label(viewModel.selectedSourceKind == .photos ? "Committing..." : "Moving...", systemImage: "hourglass")
                    } else {
                        Text(viewModel.selectedSourceKind == .photos ? "Open Summary and Queue" : "Open Summary and Commit")
                    }
                }
                .buttonStyle(.glassProminent)
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
        let previewIsCurrent = loadedPreviewRequest == previewRequest

        return HoverZoomPanel(
            image: previewIsCurrent ? hoverPreviewImage : nil,
            player: previewIsCurrent ? hoverPreviewPlayer : nil,
            isVideo: activePreviewIsVideo,
            isLoadingVideo: activePreviewIsVideo && (!previewIsCurrent || hoverPreviewLoadingVideo),
            videoPreviewErrorMessage: previewIsCurrent ? hoverPreviewVideoErrorMessage : nil,
            autoplayEnabled: viewModel.autoplayPreviewVideos,
            mediaBadges: highlightedMediaBadges,
            statusLabel: highlightedStatusLabel,
            statusColor: highlightedStatusColor,
            minimumPreviewHeight: minimumPreviewHeight,
            canOpenFocusedItem: previewIsCurrent && viewModel.canOpenFocusedItem,
            onOpenFocusedItem: viewModel.openFocusedItem
        )
        .frame(maxWidth: .infinity)
    }

    private func presentInspection() {
        guard let assetID = highlightedAssetID,
              viewModel.isPhotosAsset(assetID: assetID) else { return }
        inspectionRequest = PhotosInspectionRequest(
            group: group,
            candidateAssetIDs: [assetID],
            initiallySelectedAssetIDs: [assetID],
            comparesPhotos: false
        )
    }

    private func presentComparison() {
        let candidates = comparablePhotoAssetIDs
        guard candidates.count >= 2 else { return }
        let first = highlightedAssetID.flatMap { candidates.contains($0) ? $0 : nil } ?? candidates[0]
        guard let second = candidates.first(where: { $0 != first }) else { return }
        inspectionRequest = PhotosInspectionRequest(
            group: group,
            candidateAssetIDs: candidates,
            initiallySelectedAssetIDs: [first, second],
            comparesPhotos: true
        )
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
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                                    .glassEffect(.regular, in: Capsule())
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
                                    .glassEffect(.regular, in: Capsule())
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
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    image != nil || player != nil || isLoadingVideo || isVideo
                        ? statusColor.opacity(0.9)
                        : Color.secondary.opacity(0.35),
                    lineWidth: image != nil || player != nil || isLoadingVideo || isVideo ? 5 : 1
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

struct AppKitVideoPlayerView: NSViewRepresentable {
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
