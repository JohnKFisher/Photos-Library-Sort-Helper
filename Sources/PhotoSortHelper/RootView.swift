import AppKit
import AVFoundation
import AVKit
import SwiftUI
import Photos

struct RootView: View {
    @EnvironmentObject private var viewModel: ReviewViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var sourceSectionExpanded = true
    @State private var scanSectionExpanded = true
    @State private var reviewSectionExpanded = true

    var body: some View {
        HSplitView {
            controlsPane
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)

            reviewPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(appBackgroundColor)
        .background(
            WindowAccessor { window in
                AppDelegate.applyWindowStyle(to: window)
            }
        )
        .task {
            await viewModel.bootstrap()
        }
        .onAppear {
            applyWindowStyleToAllWindows()
        }
        .onChange(of: viewModel.isScanning) { _, _ in
            applyWindowStyleToAllWindows()
        }
        .onChange(of: viewModel.groups.count) { _, _ in
            applyWindowStyleToAllWindows()
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
    }

    private var controlsPane: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(AppMetadata.displayName)
                        .font(.title2.bold())

                    Text(AppMetadata.releaseLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(sidebarSecondaryTextColor)

                    Text("Group similar shots, keep what matters, and queue marked discards for manual cleanup.")
                        .font(.subheadline)
                        .foregroundStyle(sidebarSecondaryTextColor)

                    authorizationSection

                    SidebarDisclosureSection(
                        title: "Source",
                        systemImage: "tray.full",
                        isExpanded: $sourceSectionExpanded,
                        colorScheme: colorScheme
                    ) {
                        sourceSectionContent
                    }

                    SidebarDisclosureSection(
                        title: "Scan",
                        systemImage: "slider.horizontal.3",
                        isExpanded: $scanSectionExpanded,
                        colorScheme: colorScheme
                    ) {
                        scanSectionContent
                    }

                    SidebarDisclosureSection(
                        title: "Review",
                        systemImage: "checklist",
                        isExpanded: $reviewSectionExpanded,
                        colorScheme: colorScheme
                    ) {
                        reviewSectionContent
                    }
                }
                .padding(.top, 20 + max(0, proxy.safeAreaInsets.top))
                .padding(.bottom, 20)
                .padding(.trailing, 20)
                .padding(.leading, 20 + max(0, proxy.safeAreaInsets.leading))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                sidebarBackgroundColor
            )
        }
    }

    private var authorizationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Library Access", systemImage: "person.crop.rectangle.stack")
                .font(.headline)

            Text(accessDescription)
                .font(.footnote)
                .foregroundStyle(sidebarSecondaryTextColor)

            if !viewModel.isAuthorized {
                Button("Grant Photo Access") {
                    Task {
                        await viewModel.requestPhotoAccess()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(UITheme.sidebarSectionBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.45), lineWidth: 1)
        )
    }

    private var sourceSectionContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Look in", selection: $viewModel.sourceMode) {
                ForEach(PhotoSourceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("Choose whether to scan your full library or a specific album.")

            if viewModel.sourceMode == .album {
                if viewModel.albums.isEmpty {
                    Text("No albums available.")
                        .font(.footnote)
                        .foregroundStyle(sidebarSecondaryTextColor)
                } else {
                    Picker("Album", selection: Binding(
                        get: { viewModel.selectedAlbumID ?? viewModel.albums.first?.id ?? "" },
                        set: { viewModel.selectedAlbumID = $0 }
                    )) {
                        ForEach(viewModel.albums) { album in
                            Text(album.pickerTitle).tag(album.id)
                        }
                    }
                    .labelsHidden()
                    .help("Select the album scope used for scanning.")
                }
            }

            Toggle("Use date range", isOn: $viewModel.useDateRange)
                .help("Limit scan scope to items captured between the selected dates.")

            if viewModel.useDateRange {
                DatePicker("From", selection: $viewModel.rangeStartDate, displayedComponents: [.date])
                    .datePickerStyle(.compact)
                DatePicker("To", selection: $viewModel.rangeEndDate, displayedComponents: [.date])
                    .datePickerStyle(.compact)
            }
        }
    }

    private var scanSectionContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Stepper(value: $viewModel.maxTimeGapSeconds, in: 2...30, step: 1) {
                Text("Max time gap: \(Int(viewModel.maxTimeGapSeconds)) seconds")
            }
            .help("Shots captured within this window are considered for grouping.")

            Toggle("Include videos (slow-mo, cinematic, etc.)", isOn: $viewModel.includeVideos)
                .font(.subheadline)
                .help("Includes video assets in scans. This is slower.")
            Toggle("Auto-detect best shot per group", isOn: $viewModel.autoPickBestShot)
                .toggleStyle(.checkbox)
                .font(.subheadline)
                .help("On: quality scoring suggests what to keep/discard. Off: discard-first manual review.")
            Toggle("Autoplay videos in preview", isOn: $viewModel.autoplayPreviewVideos)
                .font(.subheadline)
                .help("Plays highlighted video previews automatically.")
            Text("Mode: \(viewModel.autoPickBestShot ? "Auto-detect" : "Discard-first manual review")")
                .font(.caption.weight(.semibold))
                .foregroundStyle(viewModel.autoPickBestShot ? UITheme.suggested : UITheme.discard)
            Text("Learning samples: \(viewModel.learnedBestShotSampleCount)")
                .font(.caption2)
                .foregroundStyle(sidebarSecondaryTextColor)
            Text("Tip: suggestions apply when you open a group, and you can override any decision.")
                .font(.caption2)
                .foregroundStyle(sidebarSecondaryTextColor)

            Button {
                viewModel.requestScan()
            } label: {
                Label(viewModel.isScanning ? "Scanning..." : "Scan for Similar Photos", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isScanning || !viewModel.isAuthorized)

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
    }

    private var reviewSectionContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                reviewMetricChip(title: "Scanned", value: "\(viewModel.scannedAssetCount)")
                reviewMetricChip(title: "Groups", value: "\(viewModel.groups.count)")
            }
            HStack(spacing: 8) {
                reviewMetricChip(title: "Clusters", value: "\(viewModel.temporalClusterCount)")
                reviewMetricChip(title: "Reviewed", value: "\(viewModel.reviewedGroupCount)/\(viewModel.groups.count)")
            }

            Text(viewModel.scanStatusMessage)
                .font(.caption)
                .foregroundStyle(sidebarSecondaryTextColor)

            Text(viewModel.estimatedDiscardSummary)
                .font(.caption)
                .foregroundStyle(sidebarSecondaryTextColor)

            Text("Queue destination: \"\(viewModel.manualDeleteAlbumName)\"")
                .font(.caption2)
                .foregroundStyle(sidebarSecondaryTextColor)

            if let deletionMessage = viewModel.deletionMessage {
                Label(deletionMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(UITheme.keep)
            }

            if viewModel.isScanning {
                ProgressView(value: viewModel.scanProgress)
            }
        }
    }

    private func reviewMetricChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(sidebarSecondaryTextColor)
            Text(value)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.65), in: RoundedRectangle(cornerRadius: 8))
    }

    private var reviewPane: some View {
        Group {
            if !viewModel.isAuthorized {
                ContentUnavailableView(
                    "Photo Access Needed",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Grant access on the left, then start a scan.")
                )
            } else if let group = viewModel.currentGroup {
                ReviewGroupView(group: group)
            } else {
                ContentUnavailableView(
                    "No Group Selected",
                    systemImage: "photo.stack",
                    description: Text("Run a scan to load similar-photo groups.")
                )
            }
        }
        .safeAreaPadding(.top, 8)
    }

    private var accessDescription: String {
        switch viewModel.authorizationStatus {
        case .authorized:
            return "Access granted."
        case .limited:
            return "Limited access granted."
        case .denied:
            return "Access denied. Enable it in System Settings > Privacy & Security > Photos."
        case .restricted:
            return "Access restricted by system policy."
        case .notDetermined:
            return "Access has not been requested yet."
        @unknown default:
            return "Unknown authorization status."
        }
    }

    private func applyWindowStyleToAllWindows() {
        for window in NSApp.windows {
            AppDelegate.applyWindowStyle(to: window)
        }
    }

    private var appBackgroundColor: Color {
        UITheme.appBackground(for: colorScheme)
    }

    private var sidebarBackgroundColor: Color {
        UITheme.sidebarBackground(for: colorScheme)
    }

    private var sidebarSecondaryTextColor: Color {
        UITheme.secondaryText(for: colorScheme)
    }
}

private struct SidebarDisclosureSection<Content: View>: View {
    let title: String
    let systemImage: String
    @Binding var isExpanded: Bool
    let colorScheme: ColorScheme
    let content: Content

    init(
        title: String,
        systemImage: String,
        isExpanded: Binding<Bool>,
        colorScheme: ColorScheme,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        _isExpanded = isExpanded
        self.colorScheme = colorScheme
        self.content = content()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(.top, 8)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
        }
        .padding(12)
        .background(UITheme.sidebarSectionBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.45), lineWidth: 1)
        )
    }
}

private struct SessionSummarySheet: View {
    @EnvironmentObject private var viewModel: ReviewViewModel
    @Binding var isPresented: Bool

    private var canQueue: Bool {
        (viewModel.discardCountTotal > 0 || viewModel.keepCountTotal > 0) && !viewModel.isDeleting && viewModel.deletionArmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Session Summary")
                .font(.title3.bold())

            Text("Review this summary before queueing kept and discarded items into their Photos albums.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            summaryRow(icon: "checklist", label: "Reviewed groups", value: "\(viewModel.reviewedGroupCount) / \(viewModel.groups.count)")
            summaryRow(icon: "checkmark.circle", label: "Marked to keep", value: "\(viewModel.keepCountTotal)")
            summaryRow(icon: "trash.slash", label: "Marked for manual delete", value: "\(viewModel.discardCountTotal)")
            summaryRow(icon: "externaldrive.badge.minus", label: "Estimated reclaim", value: viewModel.estimatedDiscardSizeLabel)
            summaryRow(icon: "folder.badge.plus", label: "Keep album", value: viewModel.fullySortedAlbumName)
            summaryRow(icon: "folder.badge.minus", label: "Discard album", value: viewModel.manualDeleteAlbumName)

            Text("Items are queued for manual review only. This app will not directly delete from your library.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(
                "I understand this queues kept items to \"\(viewModel.fullySortedAlbumName)\" and discards to \"\(viewModel.manualDeleteAlbumName)\".",
                isOn: $viewModel.deletionArmed
            )
            .toggleStyle(.checkbox)
            .font(.footnote)

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
                        Label("Queueing...", systemImage: "hourglass")
                    } else {
                        Text("Queue to \"\(viewModel.manualDeleteAlbumName)\"")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canQueue)
            }
        }
        .padding(22)
        .frame(minWidth: 500)
        .onAppear {
            viewModel.deletionArmed = false
        }
    }

    private func summaryRow(icon: String, label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.vertical, 2)
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

    private var highlightedScoreExplanation: String? {
        guard let highlightedAssetID else {
            return nil
        }

        return viewModel.bestShotExplanation(for: highlightedAssetID, in: group)
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

    private var highlightedIsSuggestedBest: Bool {
        guard let highlightedAssetID else {
            return false
        }
        return viewModel.isSuggestedBest(assetID: highlightedAssetID, in: group)
    }

    private var highlightedIsSuggestedDiscard: Bool {
        guard let highlightedAssetID else {
            return false
        }
        return viewModel.isSuggestedDiscard(assetID: highlightedAssetID, in: group)
    }

    private var reviewModeLabel: String {
        viewModel.autoPickBestShot ? "Auto-detect" : "Discard-first"
    }

    private var reviewModeColor: Color {
        viewModel.autoPickBestShot ? UITheme.suggested : UITheme.discard
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
        .animation(.spring(response: 0.26, dampingFraction: 0.84), value: viewModel.keptCountTotalReviewed)
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

            let previewCandidates = Array(group.assetIDs.prefix(3))
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
                groupIndex: viewModel.currentGroupIndex + 1,
                groupCount: viewModel.groups.count,
                reviewedCount: viewModel.reviewedGroupCount,
                keptCount: viewModel.keptCountTotalReviewed,
                discardCount: viewModel.discardCountTotalReviewed,
                totalCount: viewModel.totalAssetCountInBatch,
                estimatedDiscardSummary: viewModel.estimatedDiscardSummary,
                modeLabel: reviewModeLabel,
                modeColor: reviewModeColor
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Group \(viewModel.currentGroupIndex + 1) of \(viewModel.groups.count)")
                    .font(.title2.bold())

                Text(dateFormatter.string(from: group.startDate, to: group.endDate))
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

                Text("Keys: ↑/↓ highlight, ` keep/discard, E queue edit, ←/→ change group.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Keyboard shortcuts for faster review.")

                if let editQueueMessage = viewModel.editQueueMessage {
                    Label(editQueueMessage, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(UITheme.keep)
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
                        Label("Committing...", systemImage: "hourglass")
                    } else {
                        Text("Open Summary and Commit")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    (viewModel.discardCountTotal == 0 && viewModel.keepCountTotal == 0) ||
                    viewModel.isDeleting
                )
            }
            .padding(.top, 4)
        }
        .padding(24)
    }

    private var regularThumbnailColumn: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(group.assetIDs, id: \.self) { assetID in
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
                    ForEach(group.assetIDs, id: \.self) { assetID in
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
            isSuggestedBest: viewModel.isSuggestedBest(assetID: assetID, in: group),
            isSuggestedDiscard: viewModel.isSuggestedDiscard(assetID: assetID, in: group),
            scoreExplanation: viewModel.bestShotExplanation(for: assetID, in: group),
            isHighlighted: viewModel.isHighlighted(assetID: assetID, in: group),
            imageHeight: cardHeight,
            onSelected: {
                viewModel.setHighlighted(assetID: assetID, in: group)
            }
        )
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
            scoreExplanation: highlightedScoreExplanation,
            mediaBadges: highlightedMediaBadges,
            isKept: highlightedIsKept,
            isSuggestedBest: highlightedIsSuggestedBest,
            isSuggestedDiscard: highlightedIsSuggestedDiscard,
            minimumPreviewHeight: minimumPreviewHeight
        )
        .frame(maxWidth: .infinity)
    }
}

private struct ReviewHUDBar: View {
    let groupIndex: Int
    let groupCount: Int
    let reviewedCount: Int
    let keptCount: Int
    let discardCount: Int
    let totalCount: Int
    let estimatedDiscardSummary: String
    let modeLabel: String
    let modeColor: Color

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
                Text(modeLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(modeColor.opacity(0.9), in: Capsule())
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
            metric(title: "Keep", value: keptCount, tint: UITheme.keep)
            metric(title: "Discard", value: discardCount, tint: UITheme.discard)
            metric(title: "Reviewed", value: reviewedCount, suffix: "/\(groupCount)", tint: modeColor)
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
    let scoreExplanation: String?
    let mediaBadges: [String]
    let isKept: Bool
    let isSuggestedBest: Bool
    let isSuggestedDiscard: Bool
    let minimumPreviewHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let scoreExplanation {
                    Text(scoreExplanation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if shouldShowOverlayBadges {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Image(systemName: isKept ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)

                        Text(isKept ? "KEEPING SELECTED ITEM" : "MARKED TO DISCARD")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)

                        Spacer(minLength: 12)

                        suggestionBadgeRow
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: isKept ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)

                            Text(isKept ? "KEEPING SELECTED ITEM" : "MARKED TO DISCARD")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                        }

                        suggestionBadgeRow
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    (isKept ? UITheme.keep : UITheme.discard).opacity(0.92),
                    in: RoundedRectangle(cornerRadius: 10)
                )
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
                if shouldShowOverlayBadges {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top) {
                            mediaBadgeStrip
                            Spacer(minLength: 12)
                            overlayStatusStack(alignment: .trailing)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            mediaBadgeStrip
                                .frame(maxWidth: .infinity, alignment: .leading)
                            overlayStatusStack(alignment: .leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(18)
                }
            }
            .frame(maxWidth: .infinity, minHeight: minimumPreviewHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    shouldShowOverlayBadges
                        ? (isKept ? UITheme.keep.opacity(0.9) : UITheme.discard.opacity(0.9))
                        : Color.secondary.opacity(0.35),
                    lineWidth: shouldShowOverlayBadges ? 3 : 1
                )
        )
    }

    private var shouldShowOverlayBadges: Bool {
        image != nil || player != nil || isLoadingVideo || isVideo
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

    private var suggestionBadgeRow: some View {
        HStack(spacing: 8) {
            if isSuggestedBest {
                Text("BEST SUGGESTION")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(UITheme.suggested.opacity(0.92), in: Capsule())
                    .foregroundStyle(Color.white)
            }

            if isSuggestedDiscard {
                Text("AUTO DISCARD SUGGESTION")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(UITheme.discard.opacity(0.92), in: Capsule())
                    .foregroundStyle(Color.white)
            }
        }
    }

    private func overlayStatusStack(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            if isSuggestedDiscard {
                discardSuggestionBadge
            }
            if isSuggestedBest {
                bestShotBadge
            }
            statusBadge
        }
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
        Text(isKept ? "KEEP" : "DISCARD")
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isKept ? UITheme.keep.opacity(0.9) : UITheme.discard.opacity(0.9))
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var bestShotBadge: some View {
        Text("BEST")
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(UITheme.suggested.opacity(0.94))
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var discardSuggestionBadge: some View {
        Text("AUTO DISCARD")
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(UITheme.discard.opacity(0.94))
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

private struct WindowAccessor: NSViewRepresentable {
    let onWindowResolved: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else {
            return
        }
        onWindowResolved(window)
    }
}
