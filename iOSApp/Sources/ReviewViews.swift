import AVKit
import Photos
import PhotosSortCore
import SwiftUI

private enum ReviewPalette {
    static let keep = Color(red: 0.32, green: 0.72, blue: 0.47)
    static let discard = Color(red: 0.89, green: 0.41, blue: 0.35)
    static let edit = Color(red: 0.89, green: 0.66, blue: 0.27)
    static let panel = Color(uiColor: .secondarySystemGroupedBackground)

    static func color(for decision: ReviewDecision) -> Color {
        switch decision {
        case .keep: keep
        case .discard: discard
        case .edit: edit
        }
    }

    static func symbol(for decision: ReviewDecision) -> String {
        switch decision {
        case .keep: "checkmark"
        case .discard: "xmark"
        case .edit: "pencil"
        }
    }
}

struct ClassificationIndicator: View {
    let decision: ReviewDecision
    let origin: DecisionOrigin?
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(fillColor)
            Circle()
                .strokeBorder(ReviewPalette.color(for: decision), style: borderStyle)
            Image(systemName: ReviewPalette.symbol(for: decision))
                .font(.system(size: max(7, size * 0.42), weight: .black))
                .foregroundStyle(origin == nil ? ReviewPalette.color(for: decision) : Color.black.opacity(0.86))
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        .accessibilityHidden(true)
    }

    private var fillColor: Color {
        switch origin {
        case .explicit: ReviewPalette.color(for: decision)
        case .completedDefault: ReviewPalette.color(for: decision).opacity(0.72)
        case nil: Color(uiColor: .systemBackground).opacity(0.88)
        }
    }

    private var borderStyle: StrokeStyle {
        StrokeStyle(lineWidth: 1.25, dash: origin == .explicit ? [] : [2, 1.5])
    }
}

struct HomeView: View {
    @EnvironmentObject private var model: PhotosReviewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Review your library, one group at a time.")
                        .font(.largeTitle.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Photos Sort Helper stages your choices on this device. It never deletes a photo.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 10)

                GroupBox("Review scope") {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Source", selection: $model.sourceMode) {
                            ForEach(PhotosSourceMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: model.sourceMode) { _, mode in
                            if mode == .album { model.loadAlbumsForScope() }
                        }

                        if model.sourceMode == .album {
                            Menu {
                                if model.albums.isEmpty {
                                    Button("Load Photos albums") { model.loadAlbumsForScope() }
                                } else {
                                    ForEach(model.albums) { album in
                                        Button(album.title) { model.selectedAlbumID = album.localIdentifier }
                                    }
                                }
                            } label: {
                                HStack {
                                    Label(model.selectedAlbumTitle, systemImage: "rectangle.stack")
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                                }
                                .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Choose source album")
                        }

                        Toggle("Limit to a date range", isOn: $model.includeDateRange)
                        if model.includeDateRange {
                            DatePicker("From", selection: $model.dateFrom, displayedComponents: .date)
                            DatePicker("Through", selection: $model.dateTo, displayedComponents: .date)
                        }
                        Toggle("Include videos", isOn: $model.includeVideos)
                    }
                    .padding(.top, 7)
                }

                GroupBox("Review defaults") {
                    Picker("Review mode", selection: $model.reviewMode) {
                        ForEach(PhotosReviewMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.top, 8)
                    Text(model.reviewMode == .keepFirst
                         ? "Unmarked photos stay provisional until you complete a group."
                         : "Unmarked photos default to Discard when you complete a group.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 5)
                }

                if model.authorizationStatus == .limited {
                    Label("Full Photos access is needed to check all three review albums.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.orange)
                }

                Button {
                    model.startFromHome()
                } label: {
                    Label(model.isScanning ? "Preparing review…" : "Continue Sorting", systemImage: "arrow.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isScanning || model.isRecheckingPhotos || model.isCommitting)

                if model.isScanning {
                    ProgressView(value: model.scanProgress)
                    HStack {
                        Text(model.scanStatus).font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { model.cancelScan() }.font(.footnote.weight(.semibold))
                    }
                }

                VStack(spacing: 10) {
                    Button { model.openPendingQueue() } label: {
                        HStack {
                            Label("Review staged choices", systemImage: "tray.full")
                            Spacer()
                            Text("\(model.pendingRows.count)").font(.headline.monospacedDigit())
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(model.pendingRows.isEmpty)

                    if model.unresolvedConflictCount > 0 {
                        Button { model.openConflictReview() } label: {
                            Label("Review \(model.unresolvedConflictCount) Photos conflict(s)", systemImage: "exclamationmark.triangle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    }

                    Button {
                        model.showCommitSummary = true
                    } label: {
                        HStack {
                            Label("Commit All", systemImage: "checkmark.circle")
                            Spacer()
                            Text("\(model.commitEligibleCount)").font(.headline.monospacedDigit())
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.commitEligibleCount == 0 || model.isRecheckingPhotos || model.isCommitting)
                }
                .padding(14)
                .background(ReviewPalette.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                if !model.scanStatus.isEmpty && !model.isScanning {
                    Text(model.scanStatus).font(.footnote).foregroundStyle(.secondary)
                }
                if model.authorizationStatus == .denied || model.authorizationStatus == .restricted {
                    Button("Open Settings") { model.openAppSettings() }
                        .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 30)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.large)
    }
}

struct AlbumBindingView: View {
    @EnvironmentObject private var model: PhotosReviewModel

    var body: some View {
        if let step = model.bindingStep {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Choose the review album")
                        .font(.largeTitle.bold())
                    Text("Bind **\(step.title)** to a Photos album. The title is only a discovery hint; this device saves the album's identity.")
                        .foregroundStyle(.secondary)
                    Text("Each review role must use a different Photos album. Albums already bound to another role are omitted.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if step.needsRebind {
                        Label("A previous binding is unavailable or the album name is ambiguous. Choose the intended album explicitly.", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    VStack(spacing: 8) {
                        ForEach(step.candidates) { album in
                            Button { model.bindCurrentRole(to: album.localIdentifier) } label: {
                                HStack {
                                    Label(album.title, systemImage: "rectangle.stack")
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                                .padding(13)
                                .background(ReviewPalette.panel, in: RoundedRectangle(cornerRadius: 13))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button {
                        model.createCurrentRoleAlbum()
                    } label: {
                        Label("Create “\(step.title)” in Photos", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canCreateCurrentRoleAlbum)
                    .padding(.top, 5)
                    if !model.canCreateCurrentRoleAlbum {
                        Text("An album with this name already exists. Choose its exact identity above or rename it in Photos before creating another.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button("Refresh albums") { model.refreshAlbumChoices() }
                        .buttonStyle(.bordered)
                }
                .padding(20)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Album setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { model.returnHome() } } }
        } else {
            ProgressView("Checking albums…")
        }
    }
}

struct ReviewWorkspaceView: View {
    @EnvironmentObject private var model: PhotosReviewModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(spacing: 0) {
            reviewHeader
            if model.isScanning {
                ProgressView(value: model.scanProgress).padding(.horizontal)
                Text(model.scanStatus).font(.footnote).foregroundStyle(.secondary).padding(.vertical, 8)
                Button("Cancel preparation") { model.cancelScan() }.padding(.bottom, 12)
            } else if model.groups.isEmpty {
                emptyScope
            } else if model.currentGroup == nil {
                completedScope
            } else {
                if model.isComparing {
                    comparisonSelectionBar
                }
                if sizeClass == .regular {
                    regularWorkspace
                } else {
                    compactWorkspace
                }
                decisionControls
                groupControls
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Review Console")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { model.returnHome() } label: { Label("Home", systemImage: "house") }
                    .disabled(model.isCommitting)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { model.openPendingQueue() } label: {
                    Label("Staged \(model.pendingRows.count)", systemImage: "tray.full")
                }
                .accessibilityLabel("Review \(model.pendingRows.count) staged choices")
                Button { model.showCommitSummary = true } label: { Label("Commit", systemImage: "checkmark.circle") }
                    .disabled(model.commitEligibleCount == 0 || model.isScanning || model.isCommitting || model.isRecheckingPhotos)
            }
        }
        .onChange(of: model.libraryChanged) { _, changed in
            if changed { model.scanStatus = "Photos changed. Refreshing the review scope…" }
        }
    }

    private var reviewHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Oldest unsorted · \(min(model.currentGroupIndex + 1, max(1, model.currentGroupCount))) of \(model.currentGroupCount)")
                        .font(.caption.weight(.bold)).textCase(.uppercase).foregroundStyle(.secondary)
                    Text(model.scopeDescription()).font(.title3.bold()).lineLimit(1)
                }
                Spacer(minLength: 8)
                Menu {
                    Picker("Review mode", selection: $model.reviewMode) {
                        ForEach(PhotosReviewMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    Button("Change review scope") { model.returnHome() }
                    Button("Rescan scope") { model.scanCurrentScope() }
                        .disabled(model.isCommitting || model.isRecheckingPhotos)
                } label: {
                    Image(systemName: "slider.horizontal.3").font(.headline).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Review options")
            }
            HStack(spacing: 8) {
                Label(model.reviewMode.title, systemImage: "circle.lefthalf.filled")
                Text("·").foregroundStyle(.tertiary)
                Text(model.currentGroup.map { "\($0.itemIDs.count) photos" } ?? "No group")
                Spacer()
                if model.libraryChanged {
                    Button { model.scanCurrentScope() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise").font(.caption.weight(.semibold))
                    }
                    .disabled(model.isCommitting || model.isRecheckingPhotos)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var compactWorkspace: some View {
        VStack(spacing: 10) {
            selectedPhotoPanel
                .frame(maxHeight: .infinity)
            thumbnailNavigator
                .frame(height: 88)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var regularWorkspace: some View {
        GeometryReader { proxy in
            HStack(spacing: 14) {
                thumbnailNavigator
                    .frame(width: min(max(190, proxy.size.width * 0.22), 290))
                selectedPhotoPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var selectedPhotoPanel: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                if let player = model.currentVideoPlayer {
                    VideoPlayer(player: player)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else if let live = model.currentLivePhoto {
                    LivePhotoMediaView(livePhoto: live, startsPlayback: false)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else if let image = model.currentThumbnail {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(model.isLoadingMedia ? "Loading from Photos…" : "Preparing photo…")
                            .font(.footnote).foregroundStyle(.secondary)
                        if model.iCloudProgress > 0 && model.iCloudProgress < 1 {
                            ProgressView(value: model.iCloudProgress).frame(maxWidth: 180)
                            Text("Waiting for iCloud · \(Int(model.iCloudProgress * 100))%")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if let id = model.selectedAssetID {
                    ClassificationIndicator(decision: model.currentDecision(for: id), origin: model.currentOrigin(for: id), size: 24)
                        .padding(10)
                        .accessibilityLabel(model.statusDescription(for: id))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let id = model.selectedAssetID { model.openInspector(for: id) }
            }
            .overlay(alignment: .bottomLeading) {
                if let asset = model.selectedAssetID.flatMap(model.assetForID) {
                    Text(asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? String(asset.localIdentifier.suffix(10)))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(10)
                        .accessibilityHidden(true)
                }
            }
            HStack {
                Text(model.selectedAssetID.map(model.statusDescription(for:)) ?? model.reviewMode.shortDefault)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { model.beginComparison() } label: {
                    Label("Compare", systemImage: "rectangle.split.2x1").font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .disabled((model.currentGroup?.itemIDs.count ?? 0) < 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var thumbnailNavigator: some View {
        Group {
            if let group = model.currentGroup {
                ScrollView(sizeClass == .regular ? .vertical : .horizontal) {
                    if sizeClass == .regular {
                        LazyVStack(spacing: 8) {
                            ForEach(group.itemIDs, id: \.self) { id in thumbnailButton(id, dimension: 64) }
                        }
                        .padding(8)
                    } else {
                        LazyHStack(spacing: 9) {
                            ForEach(group.itemIDs, id: \.self) { id in thumbnailButton(id, dimension: 72) }
                        }
                        .padding(.horizontal, 2)
                    }
                }
                .background(ReviewPalette.panel, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .accessibilityLabel("Group photo navigator")
            }
        }
    }

    private func thumbnailButton(_ id: String, dimension: CGFloat) -> some View {
        Button {
            if model.isComparing { model.toggleCompareAsset(id) } else { model.selectItem(id) }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                PhotoAssetThumbnail(assetID: id)
                    .frame(width: dimension, height: dimension * 0.76)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                ClassificationIndicator(decision: model.currentDecision(for: id), origin: model.currentOrigin(for: id), size: 18)
                    .padding(4)
                if model.isComparing && model.compareAssetIDs.contains(id) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3).foregroundStyle(.white, .blue)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(4)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(model.selectedAssetID == id ? Color.accentColor : Color.clear, lineWidth: 2.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Photo, \(model.statusDescription(for: id))\(model.selectedAssetID == id ? ", selected" : "")")
        .accessibilityAddTraits(model.selectedAssetID == id ? .isSelected : [])
    }

    private var decisionControls: some View {
        HStack(spacing: 9) {
            decisionButton(.keep, title: "Keep")
            decisionButton(.discard, title: "Discard")
            decisionButton(.edit, title: "Edit")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func decisionButton(_ decision: ReviewDecision, title: String) -> some View {
        Button {
            if let id = model.selectedAssetID { model.setDecision(decision, for: id) }
        } label: {
            Label(title, systemImage: ReviewPalette.symbol(for: decision))
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(.borderedProminent)
        .tint(ReviewPalette.color(for: decision))
        .foregroundStyle(.black.opacity(0.88))
        .accessibilityHint("Stages this choice locally for the selected photo.")
        .disabled(model.selectedAssetID == nil)
    }

    private var groupControls: some View {
        HStack(spacing: 8) {
            Button { model.moveGroup(by: -1) } label: {
                Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(!model.hasPreviousGroup)
            .accessibilityLabel("Previous group")

            Button("Skip") { model.skipCurrentGroup() }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)

            Button {
                model.completeCurrentGroup()
            } label: {
                Label(model.hasNextGroup ? "Next Group" : "Complete Group", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)

        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var comparisonSelectionBar: some View {
        HStack {
            Label("Choose two photos to compare · \(model.compareAssetIDs.count)/2", systemImage: "rectangle.split.2x1")
                .font(.caption.weight(.semibold))
            Spacer()
            Button("Done") { model.isComparing = false }
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.accentColor.opacity(0.12))
    }

    private var emptyScope: some View {
        ContentUnavailableView {
            Label("Nothing unsorted in this scope", systemImage: "checkmark.circle")
        } description: {
            Text("Choose another album or date range, or refresh after Photos changes.")
        } actions: {
            Button("Change scope") { model.returnHome() }.buttonStyle(.borderedProminent)
            Button("Refresh") { model.scanCurrentScope() }
                .buttonStyle(.bordered)
                .disabled(model.isCommitting || model.isRecheckingPhotos)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var completedScope: some View {
        ContentUnavailableView {
            Label("Review pass complete", systemImage: "checkmark.circle.fill")
        } description: {
            Text("Your staged choices remain available to revisit and commit. Start another scope or return to an earlier group.")
        } actions: {
            Button("Previous group") { model.moveGroup(by: -1) }.buttonStyle(.bordered)
            Button("Change scope") { model.returnHome() }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PhotoAssetThumbnail: View {
    @EnvironmentObject private var model: PhotosReviewModel
    let assetID: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color(uiColor: .tertiarySystemFill))
                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
        }
        .clipped()
        .task(id: assetID) { image = await model.thumbnail(for: assetID) }
        .accessibilityHidden(true)
    }
}

struct PendingQueueView: View {
    @EnvironmentObject private var model: PhotosReviewModel

    var body: some View {
        List {
            Section {
                Text("Staged choices stay on this device until Photos confirms the commit. Revisit any item to change its classification.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if model.pendingRows.isEmpty {
                ContentUnavailableView("No staged choices", systemImage: "tray", description: Text("Review a group to stage choices here."))
            } else {
                Section("Keep · \(model.keepCount)") {
                    ForEach(model.pendingRows.filter { $0.decision == .keep }) { row in pendingRow(row) }
                }
                Section("Discard · \(model.discardCount)") {
                    ForEach(model.pendingRows.filter { $0.decision == .discard }) { row in pendingRow(row) }
                }
                Section("Edit · \(model.editCount)") {
                    ForEach(model.pendingRows.filter { $0.decision == .edit }) { row in pendingRow(row) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Staged choices")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Home") { model.returnHome() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.showCommitSummary = true } label: { Label("Commit All", systemImage: "checkmark.circle") }
                    .disabled(model.commitEligibleCount == 0 || model.isCommitting || model.isRecheckingPhotos)
            }
        }
    }

    private func pendingRow(_ row: PendingReviewItem) -> some View {
        Button { model.openPendingItem(row) } label: {
            HStack(spacing: 12) {
                PhotoAssetThumbnail(assetID: row.assetID)
                    .frame(width: 62, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.assetID.suffix(18)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(model.statusDescription(for: row.assetID)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if row.status != .pending {
                    Image(systemName: row.status == .conflict ? "exclamationmark.triangle.fill" : "icloud.slash")
                        .foregroundStyle(row.status == .conflict ? .orange : .secondary)
                        .accessibilityLabel(row.status == .conflict ? "Conflict" : "Unavailable")
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}

struct PendingItemReviewView: View {
    @EnvironmentObject private var model: PhotosReviewModel

    var body: some View {
        VStack(spacing: 14) {
            if let row = model.pendingSelection {
                Text(model.statusDescription(for: row.assetID)).font(.headline)
                if let asset = model.assetForID(row.assetID) {
                    PhotoAssetInspector(assetID: row.assetID, asset: asset)
                        .frame(maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Photo unavailable", systemImage: "photo.badge.exclamationmark", description: Text("This item remains staged until Photos makes it available again."))
                }
                HStack(spacing: 9) {
                    queueDecisionButton(.keep)
                    queueDecisionButton(.discard)
                    queueDecisionButton(.edit)
                }
                if row.status == .conflict {
                    Text("This photo's Photos album membership conflicts with its staged choice. Change membership in Photos, then recheck.")
                        .font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
            }
        }
        .padding(14)
        .navigationTitle("Revisit staged item")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Queue") { model.openPendingQueue() } }
            ToolbarItem(placement: .topBarTrailing) { Button("Next") { model.selectNextPending() } }
        }
    }

    private func queueDecisionButton(_ decision: ReviewDecision) -> some View {
        Button {
            model.classifyPending(decision)
        } label: {
            Label(model.decisionTitle(decision), systemImage: ReviewPalette.symbol(for: decision))
                .frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(.borderedProminent)
        .tint(ReviewPalette.color(for: decision))
        .foregroundStyle(.black.opacity(0.88))
    }
}

struct ConflictReviewView: View {
    @EnvironmentObject private var model: PhotosReviewModel

    var body: some View {
        List {
            Section {
                Label("Conflict state is retained locally. This app never moves a photo between review albums or resolves conflicting memberships automatically.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
                Button { model.recheckConflicts() } label: {
                    Label(model.isRecheckingPhotos ? "Checking Photos…" : "Recheck Photos", systemImage: "arrow.clockwise")
                }
                .disabled(!model.isAuthorized || model.isRecheckingPhotos || model.isScanning || model.isCommitting)
            }
            Section("Needs review") {
                ForEach(model.pendingRows.filter { $0.status != .pending }) { row in
                    Button { model.openPendingItem(row) } label: {
                        HStack(spacing: 12) {
                            ClassificationIndicator(decision: row.decision, origin: row.origin, size: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.assetID.suffix(18)).font(.subheadline.weight(.semibold))
                                Text(row.status == .conflict
                                     ? "Membership disagrees with \(model.destinationTitle(model.target(for: row.decision)))"
                                     : "Photo is unavailable or not mapped in this library")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Photos conflicts")
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Home") { model.returnHome() } } }
    }
}

struct CommitSummaryView: View {
    @EnvironmentObject private var model: PhotosReviewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 15) {
                Text("Review before Photos changes")
                    .font(.title2.bold())
                Text("Only staged items with a current, non-conflicting Photos membership are eligible. Nothing will be deleted.")
                    .font(.subheadline).foregroundStyle(.secondary)
                summaryRow("Fully Sorted · Keep", count: model.keepCount)
                summaryRow("Files to Manually Delete · Discard", count: model.discardCount)
                summaryRow("Files to Edit", count: model.editCount)
                if model.unresolvedConflictCount > 0 || model.unavailableCount > 0 {
                    Label("\(model.unresolvedConflictCount) conflict(s) and \(model.unavailableCount) unavailable item(s) stay staged.", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Spacer(minLength: 4)
                if model.isCommitting {
                    ProgressView(model.commitProgress)
                }
                Button {
                    dismiss()
                    model.commitAll()
                } label: {
                    Label("Commit \(model.commitEligibleCount) eligible item(s)", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.commitEligibleCount == 0 || model.isCommitting || model.isRecheckingPhotos)
                Button("Review staged choices") { dismiss(); model.openPendingQueue() }
                    .frame(maxWidth: .infinity, minHeight: 44)
                Text("Photos album changes are checked again before and after commit. If another device changed an item, it remains staged for review.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .navigationTitle("Commit All")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
    }

    private func summaryRow(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(count.formatted()).font(.title3.bold().monospacedDigit())
        }
        .padding(12)
        .background(ReviewPalette.panel, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PhotoInspectorSheet: View {
    @EnvironmentObject private var model: PhotosReviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let id = model.selectedAssetID, let asset = model.assetForID(id) {
                    PhotoAssetInspector(assetID: id, asset: asset, zoom: $zoom, pan: $pan)
                    Text(model.statusDescription(for: id)).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        inspectorDecision(.keep)
                        inspectorDecision(.discard)
                        inspectorDecision(.edit)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .navigationTitle("Inspect photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { model.closeInspector(); dismiss() } } }
            .onDisappear { model.closeInspector() }
        }
    }

    private func inspectorDecision(_ decision: ReviewDecision) -> some View {
        Button {
            if let id = model.selectedAssetID { model.setDecision(decision, for: id) }
        } label: {
            Label(model.decisionTitle(decision), systemImage: ReviewPalette.symbol(for: decision))
                .frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(.borderedProminent)
        .tint(ReviewPalette.color(for: decision))
        .foregroundStyle(.black.opacity(0.88))
    }
}

struct PhotoAssetInspector: View {
    @EnvironmentObject private var model: PhotosReviewModel
    let assetID: String
    let asset: PHAsset
    @Binding var zoom: CGFloat
    @Binding var pan: CGSize
    @State private var image: UIImage?
    @State private var livePhoto: PHLivePhoto?
    @State private var player: AVPlayer?

    init(assetID: String, asset: PHAsset, zoom: Binding<CGFloat> = .constant(1), pan: Binding<CGSize> = .constant(.zero)) {
        self.assetID = assetID
        self.asset = asset
        _zoom = zoom
        _pan = pan
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let player {
                    VideoPlayer(player: player)
                } else if let livePhoto {
                    LivePhotoMediaView(livePhoto: livePhoto, startsPlayback: true)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(zoom)
                        .offset(pan)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { zoom = min(max($0, 1), 5) }
                                .onEnded { value in if value <= 1.02 { zoom = 1; pan = .zero } }
                                .simultaneously(with: DragGesture().onChanged { pan = $0.translation })
                        )
                } else {
                    VStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text(model.isLoadingMedia ? "Waiting for Photos or iCloud…" : "Loading original…")
                            .font(.footnote).foregroundStyle(.white.opacity(0.8))
                        if model.iCloudProgress > 0 && model.iCloudProgress < 1 {
                            ProgressView(value: model.iCloudProgress).frame(maxWidth: 220)
                            Text("\(Int(model.iCloudProgress * 100))%")
                                .font(.caption2).foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .task(id: assetID) { await load() }
        .onDisappear { player?.pause() }
        .accessibilityElement(children: .contain)
    }

    private func load() async {
        image = nil
        livePhoto = nil
        player?.pause()
        player = nil
        model.isLoadingMedia = true
        model.iCloudProgress = 0
        defer { model.isLoadingMedia = false }
        if asset.mediaType == .video {
            let avAsset = await PhotoKitMediaLoader.video(for: asset) { progress in
                Task { @MainActor in model.iCloudProgress = progress }
            }
            guard !Task.isCancelled else { return }
            if let avAsset { player = AVPlayer(playerItem: AVPlayerItem(asset: avAsset)) }
            return
        }
        if asset.mediaSubtypes.contains(.photoLive) {
            livePhoto = await PhotoKitMediaLoader.livePhoto(for: asset, targetSize: CGSize(width: 2_400, height: 2_400)) { progress in
                Task { @MainActor in model.iCloudProgress = progress }
            }
        }
        guard !Task.isCancelled else { return }
        image = await PhotoKitMediaLoader.image(for: asset, targetSize: CGSize(width: 2_400, height: 2_400), deliveryMode: .highQualityFormat) { progress in
            Task { @MainActor in model.iCloudProgress = progress }
        }
    }
}

struct ComparisonSheet: View {
    @EnvironmentObject private var model: PhotosReviewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var activeID: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text("Choose two photos from this group. Each photo keeps its own classification.")
                    .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                if let group = model.currentGroup {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(group.itemIDs, id: \.self) { id in
                                Button { model.toggleCompareAsset(id) } label: {
                                    ZStack(alignment: .bottomTrailing) {
                                        PhotoAssetThumbnail(assetID: id).frame(width: 70, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
                                        ClassificationIndicator(decision: model.currentDecision(for: id), origin: model.currentOrigin(for: id), size: 17).padding(3)
                                        if model.compareAssetIDs.contains(id) {
                                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .blue).padding(3).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(model.statusDescription(for: id))\(model.compareAssetIDs.contains(id) ? ", selected for comparison" : "")")
                            }
                        }
                    }
                    if model.compareAssetIDs.count == 2 {
                        let selected = Array(model.compareAssetIDs).sorted()
                        if sizeClass == .regular {
                            HStack(spacing: 10) {
                                ForEach(selected, id: \.self) { comparisonPane($0) }
                            }
                        } else {
                            Picker("Comparison photo", selection: Binding(
                                get: { activeID ?? selected.first ?? "" },
                                set: { activeID = $0 }
                            )) {
                                ForEach(selected, id: \.self) { Text($0.suffix(8)).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            if let id = activeID ?? selected.first { comparisonPane(id) }
                        }
                    } else {
                        ContentUnavailableView("Select two photos", systemImage: "rectangle.split.2x1", description: Text("Tap two thumbnails above to compare them."))
                    }
                }
            }
            .padding(14)
            .navigationTitle("Compare photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { model.isComparing = false; dismiss() } } }
        }
    }

    private func comparisonPane(_ id: String) -> some View {
        VStack(spacing: 7) {
            PhotoAssetThumbnail(assetID: id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .onTapGesture { activeID = id; model.openInspector(for: id) }
            Text(model.statusDescription(for: id)).font(.caption).lineLimit(1)
            HStack(spacing: 5) {
                miniDecision(.keep, for: id)
                miniDecision(.discard, for: id)
                miniDecision(.edit, for: id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func miniDecision(_ decision: ReviewDecision, for id: String) -> some View {
        Button {
            model.selectItem(id)
            model.setDecision(decision, for: id)
        } label: {
            Image(systemName: ReviewPalette.symbol(for: decision))
                .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.borderedProminent)
        .tint(ReviewPalette.color(for: decision))
        .foregroundStyle(.black.opacity(0.88))
        .accessibilityLabel("\(model.decisionTitle(decision)) \(id.suffix(8))")
    }
}
