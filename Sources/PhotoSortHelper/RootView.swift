import AppKit
import AVFoundation
import AVKit
import SwiftUI
import Photos

struct RootView: View {
    @EnvironmentObject private var viewModel: ReviewViewModel
    @Environment(\.colorScheme) private var colorScheme

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
        .alert("Delete Marked Photos?", isPresented: $viewModel.showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Recently Deleted", role: .destructive) {
                viewModel.deleteMarkedAssets()
            }
        } message: {
            Text(
                "This moves \(viewModel.discardCountTotal) photo(s) to Recently Deleted in Apple Photos.\n\(viewModel.estimatedDiscardSummary)\nNothing is permanently erased immediately, but this still changes your library."
            )
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
                VStack(alignment: .leading, spacing: 18) {
                    Text(AppMetadata.displayName)
                        .font(.title2.bold())

                    Text(AppMetadata.releaseLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(sidebarSecondaryTextColor)

                    Text("Find very similar photos taken close together, then decide what to keep. By default, everything is kept until you explicitly mark photos to discard.")
                        .font(.subheadline)
                        .foregroundStyle(sidebarSecondaryTextColor)

                    Divider()

                    authorizationSection

                    Divider()

                    sourceSection

                    Divider()

                    scanSettingsSection

                    Button {
                        viewModel.scan()
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

                    if viewModel.isScanning {
                        ProgressView(value: viewModel.scanProgress)
                        Text(viewModel.scanStatusMessage)
                            .font(.caption)
                            .foregroundStyle(sidebarSecondaryTextColor)
                    } else {
                        Text(viewModel.scanStatusMessage)
                            .font(.caption)
                            .foregroundStyle(sidebarSecondaryTextColor)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scanned photos: \(viewModel.scannedAssetCount)")
                        Text("Time-near clusters: \(viewModel.temporalClusterCount)")
                        Text("Review groups: \(viewModel.groups.count)")
                    }
                    .font(.footnote)
                    .foregroundStyle(sidebarSecondaryTextColor)

                    if let deletionMessage = viewModel.deletionMessage {
                        Label(deletionMessage, systemImage: "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.green)
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Library Access")
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
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Source")
                .font(.headline)

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
                }
            }

            Toggle("Use date range", isOn: $viewModel.useDateRange)

            if viewModel.useDateRange {
                DatePicker("From", selection: $viewModel.rangeStartDate, displayedComponents: [.date])
                    .datePickerStyle(.compact)
                DatePicker("To", selection: $viewModel.rangeEndDate, displayedComponents: [.date])
                    .datePickerStyle(.compact)
            }
        }
    }

    private var scanSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scan Settings")
                .font(.headline)

            Stepper(value: $viewModel.maxTimeGapSeconds, in: 2...30, step: 1) {
                Text("Max time gap: \(Int(viewModel.maxTimeGapSeconds)) seconds")
            }

            Toggle("Include videos (slow-mo, cinematic, etc.)", isOn: $viewModel.includeVideos)
                .font(.subheadline)
            Toggle("Auto-pick best shot per group", isOn: $viewModel.autoPickBestShot)
                .font(.subheadline)
            Toggle("Autoplay videos in preview", isOn: $viewModel.autoplayPreviewVideos)
                .font(.subheadline)
            Text("Auto-pick uses face/eyes/smile, framing, focus, lighting, and color heuristics. Suggestions are only applied after you open each group, and you can always override manually.")
                .font(.caption)
                .foregroundStyle(sidebarSecondaryTextColor)
            Text("Singleton photos that score as clearly low quality (for example, very blurry or near-black accidental shots) can also be auto-suggested as discard.")
                .font(.caption)
                .foregroundStyle(sidebarSecondaryTextColor)
            Text("Learning from your choices: \(viewModel.learnedBestShotSampleCount) reviewed group\(viewModel.learnedBestShotSampleCount == 1 ? "" : "s"). A deeper model tie-break runs only when top picks are very close.")
                .font(.caption)
                .foregroundStyle(sidebarSecondaryTextColor)
            Text("Videos are off by default. Photos always include all image types (RAW, panorama, spatial, and more).")
                .font(.caption)
                .foregroundStyle(sidebarSecondaryTextColor)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Similarity threshold")
                    Spacer()
                    Text(String(format: "%.1f", viewModel.similarityDistanceThreshold))
                        .monospacedDigit()
                }
                Slider(value: $viewModel.similarityDistanceThreshold, in: 6...22, step: 0.5)
                Text("Lower values are stricter. Start around 12.0.")
                    .font(.caption)
                    .foregroundStyle(sidebarSecondaryTextColor)
            }

            Stepper(value: $viewModel.maxAssetsToScan, in: 200...12_000, step: 200) {
                Text("Max photos to scan: \(viewModel.maxAssetsToScan)")
            }
            .help("Caps scan size for performance. Increase if needed.")
        }
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
        if colorScheme == .dark {
            return Color(nsColor: NSColor(calibratedWhite: 0.11, alpha: 1.0))
        }
        return Color(red: 0.96, green: 0.98, blue: 1.0).opacity(0.45)
    }

    private var sidebarBackgroundColor: Color {
        if colorScheme == .dark {
            return Color(nsColor: NSColor(calibratedWhite: 0.16, alpha: 1.0))
        }
        return Color(red: 0.97, green: 0.985, blue: 1.0).opacity(0.5)
    }

    private var sidebarSecondaryTextColor: Color {
        if colorScheme == .dark {
            return Color(nsColor: .secondaryLabelColor).opacity(0.98)
        }
        return .secondary
    }
}

private struct ReviewGroupView: View {
    @EnvironmentObject private var viewModel: ReviewViewModel
    let group: ReviewGroup
    @State private var hoverPreviewImage: NSImage?
    @State private var hoverPreviewPlayer: AVPlayer?
    @State private var hoverPreviewLoadingVideo = false

    private let dateFormatter: DateIntervalFormatter = {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private let thumbnailColumnWidth: CGFloat = 250

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

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Group \(viewModel.currentGroupIndex + 1) of \(viewModel.groups.count)")
                        .font(.title2.bold())

                    Text(dateFormatter.string(from: group.startDate, to: group.endDate))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Text("Keep: \(viewModel.keptCount(in: group))  •  Discard: \(viewModel.discardCount(in: group))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text(viewModel.isGroupReviewed(group) ? "Reviewed" : "Unreviewed")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                (viewModel.isGroupReviewed(group) ? Color.green : Color.orange)
                                    .opacity(0.88),
                                in: Capsule()
                            )
                            .foregroundStyle(.white)
                    }
                }

                Spacer()

                HStack(spacing: 10) {
                    Button("Previous") {
                        viewModel.previousGroup()
                    }
                    .frame(minWidth: 110)
                    .disabled(viewModel.currentGroupIndex == 0)

                    Button("Next") {
                        viewModel.nextGroup()
                    }
                    .frame(minWidth: 110)
                    .disabled(viewModel.currentGroupIndex >= viewModel.groups.count - 1)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button("Keep all") {
                        viewModel.keepAll(in: group)
                    }
                    .frame(minWidth: 110)

                    Button("Discard all") {
                        viewModel.discardAll(in: group)
                    }
                    .frame(minWidth: 120)
                }

                Text("Tip: up/down changes highlight, ` toggles keep/discard, left/right changes group.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 20) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(group.assetIDs, id: \.self) { assetID in
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
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: highlightedAssetID) { _, newID in
                        scrollToHighlighted(newID, with: proxy)
                    }
                }
                .frame(minWidth: thumbnailColumnWidth, idealWidth: thumbnailColumnWidth, maxWidth: thumbnailColumnWidth)
                .frame(maxHeight: .infinity)

                HoverZoomPanel(
                    image: hoverPreviewImage,
                    player: hoverPreviewPlayer,
                    isVideo: activePreviewIsVideo,
                    isLoadingVideo: hoverPreviewLoadingVideo,
                    autoplayEnabled: viewModel.autoplayPreviewVideos,
                    scoreExplanation: highlightedScoreExplanation,
                    mediaBadges: highlightedMediaBadges,
                    isKept: highlightedIsKept,
                    isSuggestedBest: highlightedIsSuggestedBest,
                    isSuggestedDiscard: highlightedIsSuggestedDiscard
                )
                    .frame(minWidth: 920, idealWidth: 1020, maxWidth: .infinity)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Marked for discard across reviewed groups: \(viewModel.discardCountTotal)")
                            .font(.headline)
                        Text("Reviewed groups: \(viewModel.reviewedGroupCount) of \(viewModel.groups.count)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(viewModel.estimatedDiscardSummary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("Nothing is deleted until you arm deletion, then confirm.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(role: .destructive) {
                        viewModel.confirmDeleteMarkedAssets()
                    } label: {
                        if viewModel.isDeleting {
                            ProgressView()
                                .progressViewStyle(.circular)
                        } else {
                            Text("Move Marked Photos to Recently Deleted")
                        }
                    }
                    .disabled(
                        viewModel.discardCountTotal == 0 ||
                        viewModel.isDeleting ||
                        !viewModel.deletionArmed
                    )
                }

                Toggle(
                    "I understand this changes my Photos library and moves marked items to Recently Deleted.",
                    isOn: $viewModel.deletionArmed
                )
                .toggleStyle(.checkbox)
                .font(.footnote)
            }
        }
        .padding(24)
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
        }
    }

    private func loadPreview(for assetID: String?) async {
        guard let assetID else {
            hoverPreviewImage = nil
            hoverPreviewPlayer?.pause()
            hoverPreviewPlayer = nil
            hoverPreviewLoadingVideo = false
            return
        }

        let activeID = assetID

        hoverPreviewPlayer?.pause()
        hoverPreviewPlayer = nil
        hoverPreviewLoadingVideo = false

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

            if let player = await viewModel.previewPlayer(for: activeID), highlightedAssetID == activeID {
                hoverPreviewPlayer = player
                hoverPreviewLoadingVideo = false
                updateVideoPlaybackState()
            } else if highlightedAssetID == activeID {
                hoverPreviewLoadingVideo = false
            }

            return
        }

        hoverPreviewImage = nil

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
}

private struct HoverZoomPanel: View {
    let image: NSImage?
    let player: AVPlayer?
    let isVideo: Bool
    let isLoadingVideo: Bool
    let autoplayEnabled: Bool
    let scoreExplanation: String?
    let mediaBadges: [String]
    let isKept: Bool
    let isSuggestedBest: Bool
    let isSuggestedDiscard: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Preview Box (Hover)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let scoreExplanation {
                    Text(scoreExplanation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            if shouldShowOverlayBadges {
                HStack(spacing: 10) {
                    Image(systemName: isKept ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)

                    Text(isKept ? "KEEPING SELECTED ITEM" : "MARKED TO DISCARD")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)

                    Spacer()

                    if isSuggestedBest {
                        Text("BEST SUGGESTION")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.22), in: Capsule())
                            .foregroundStyle(.white)
                    }

                    if isSuggestedDiscard {
                        Text("AUTO DISCARD SUGGESTION")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.22), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    (isKept ? Color.green : Color.red).opacity(0.9),
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
                } else if isLoadingVideo {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Loading video preview...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else if isVideo {
                    Text("Video preview unavailable for this item.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Select or hover a thumbnail to preview it here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .top) {
                if shouldShowOverlayBadges {
                    HStack(alignment: .top) {
                        mediaBadgeStrip
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            if isSuggestedDiscard {
                                discardSuggestionBadge
                            }
                            if isSuggestedBest {
                                bestShotBadge
                            }
                            statusBadge
                        }
                    }
                    .padding(18)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 460, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    shouldShowOverlayBadges
                        ? (isKept ? Color.green.opacity(0.9) : Color.red.opacity(0.9))
                        : Color.secondary.opacity(0.35),
                    lineWidth: shouldShowOverlayBadges ? 3 : 1
                )
        )
    }

    private var shouldShowOverlayBadges: Bool {
        image != nil || player != nil || isLoadingVideo || isVideo
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
                        .background(Color.black.opacity(0.65))
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
            .background(isKept ? Color.green.opacity(0.85) : Color.red.opacity(0.85))
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var bestShotBadge: some View {
        Text("BEST")
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.9))
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var discardSuggestionBadge: some View {
        Text("AUTO DISCARD")
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.red.opacity(0.92))
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
