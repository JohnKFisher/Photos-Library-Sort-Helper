import AVKit
import AppKit
import Photos
import PhotosUI
import PhotosSortCore
import SwiftUI

struct PhotosInspectionRequest: Identifiable {
    let id = UUID()
    let group: ReviewGroup
    let candidateAssetIDs: [String]
    let initiallySelectedAssetIDs: [String]
    let comparesPhotos: Bool
}

@MainActor
struct PhotosInspectionWorkspace: View {
    @EnvironmentObject private var viewModel: ReviewViewModel

    let request: PhotosInspectionRequest

    @State private var firstAssetID: String
    @State private var secondAssetID: String

    init(request: PhotosInspectionRequest) {
        self.request = request
        _firstAssetID = State(initialValue: request.initiallySelectedAssetIDs.first ?? request.candidateAssetIDs.first ?? "")
        _secondAssetID = State(initialValue: request.initiallySelectedAssetIDs.dropFirst().first ?? request.candidateAssetIDs.first(where: { $0 != request.initiallySelectedAssetIDs.first }) ?? "")
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.comparesPhotos ? "Compare Photos" : "Inspect Media")
                        .font(.title2.weight(.semibold))
                    Text("Choices stay independent. No photo is selected as a winner.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(viewModel.reviewMode.title)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.13), in: Capsule())
            }

            if request.comparesPhotos {
                HStack(spacing: 12) {
                    photoPicker(title: "Photo A", selection: $firstAssetID)
                    photoPicker(title: "Photo B", selection: $secondAssetID)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                InspectionPane(assetID: firstAssetID, group: request.group)
                    .id("first-\(firstAssetID)")
                if request.comparesPhotos {
                    InspectionPane(assetID: secondAssetID, group: request.group)
                        .id("second-\(secondAssetID)")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(18)
        .frame(minWidth: request.comparesPhotos ? 960 : 680, minHeight: 590)
        .background(.regularMaterial)
    }

    private func photoPicker(title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(request.candidateAssetIDs, id: \.self) { assetID in
                Text(viewModel.itemTitle(assetID: assetID)).tag(assetID)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(title)
    }
}

@MainActor
private struct InspectionPane: View {
    @EnvironmentObject private var viewModel: ReviewViewModel
    @Environment(\.displayScale) private var backingScale

    let assetID: String
    let group: ReviewGroup

    @State private var image: NSImage?
    @State private var livePhoto: PHLivePhoto?
    @State private var player: AVPlayer?
    @State private var playerResourceLease: AnyObject?
    @State private var isLoading = false
    @State private var progress = 0.0
    @State private var statusMessage = ""
    @State private var isMaximumSizeLoaded = false
    @State private var showAtActualSize = false
    @State private var isPlayingLivePhoto = false
    @State private var zoomResetID = UUID()
    @State private var requestTask: Task<Void, Never>?
    @State private var activeRequestID: UUID?
    @State private var paneSize = CGSize(width: 500, height: 400)

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.88))
                    if let player {
                        AppKitVideoPlayerView(player: player)
                            .padding(8)
                    } else if let livePhoto {
                        AppKitLivePhotoView(livePhoto: livePhoto, isPlaying: isPlayingLivePhoto)
                            .padding(8)
                    } else if let image {
                        ZoomableInspectionImage(
                            image: image,
                            initiallyAtActualSize: showAtActualSize,
                            resetID: zoomResetID,
                            backingScale: backingScale
                        )
                        .padding(8)
                    } else if isLoading {
                        VStack(spacing: 9) {
                            ProgressView(value: progress > 0 ? progress : nil)
                                .frame(maxWidth: 220)
                            Text(progress > 0 ? "Loading from Photos · \(Int(progress * 100))%" : "Loading from Photos…")
                                .font(.callout)
                                .foregroundStyle(.white)
                        }
                    } else {
                        ContentUnavailableView(
                            "Preview Unavailable",
                            systemImage: "photo",
                            description: Text(statusMessage.isEmpty ? "Choose an inspection action to load this item." : statusMessage)
                        )
                        .foregroundStyle(.white)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .onAppear {
                    paneSize = geometry.size
                    if viewModel.isVideo(assetID: assetID) {
                        requestVideo(in: geometry.size)
                    } else {
                        requestStill(in: geometry.size, maximumSize: false)
                    }
                }
                .onChange(of: geometry.size) { _, newSize in
                    paneSize = newSize
                    guard !isMaximumSizeLoaded, !viewModel.isVideo(assetID: assetID), livePhoto == nil else { return }
                    requestStill(in: newSize, maximumSize: false)
                }
            }
            .frame(minHeight: 410)

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.itemTitle(assetID: assetID))
                        .font(.headline)
                        .lineLimit(1)
                    Text(viewModel.reviewStateDescription(assetID: assetID, in: group))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if isLoading {
                    Button("Cancel Download") { cancelRequest() }
                }
            }

            if isLoading {
                ProgressView(value: progress > 0 ? progress : nil)
                    .accessibilityLabel("Loading media from Photos")
            }
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            }

            HStack(spacing: 7) {
                if !viewModel.isVideo(assetID: assetID) {
                    Button("Fit") {
                        showAtActualSize = false
                        zoomResetID = UUID()
                    }
                    .help("Fit the image to this pane.")
                    Button(isMaximumSizeLoaded ? "Actual Size" : "Load Actual Size") {
                        if isMaximumSizeLoaded {
                            showAtActualSize = true
                            zoomResetID = UUID()
                        } else {
                            requestStill(in: CGSize(width: 1_000, height: 800), maximumSize: true)
                        }
                    }
                    .help("Load the current full-size Photos rendition for pixel-level inspection.")
                    .disabled(isLoading)

                    if viewModel.isLivePhoto(assetID: assetID) {
                        Button(livePhoto == nil ? "Play Live Photo" : (isPlayingLivePhoto ? "Stop Live Photo" : "Replay Live Photo")) {
                            if livePhoto != nil {
                                isPlayingLivePhoto.toggle()
                            } else {
                                requestLivePhoto(in: CGSize(width: 1_000, height: 800))
                            }
                        }
                        .disabled(isLoading)
                    }
                    if livePhoto != nil {
                        Button("Show Still Photo") {
                            isPlayingLivePhoto = false
                            livePhoto = nil
                        }
                    }
                } else if player != nil {
                    Label("Video controls are provided by Photos playback.", systemImage: "play.rectangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !isLoading {
                    Button("Load Video") { requestVideo(in: paneSize) }
                }

                Spacer(minLength: 5)
                decisionButton(.keep, color: .green)
                decisionButton(.discard, color: .red)
                decisionButton(.edit, color: .orange)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
        .onDisappear {
            cancelRequest(clearMedia: true)
        }
    }

    private func decisionButton(_ decision: ReviewDecision, color: Color) -> some View {
        Button(decision.rawValue.capitalized) {
            viewModel.setReviewDecision(decision, assetID: assetID, in: group)
        }
        .tint(color)
        .accessibilityLabel("Set \(decision.rawValue.capitalized) for \(viewModel.itemTitle(assetID: assetID))")
    }

    private func requestStill(in paneSize: CGSize, maximumSize: Bool) {
        guard !viewModel.isVideo(assetID: assetID) else { return }
        cancelRequest(clearMedia: false)
        player?.pause()
        player = nil
        livePhoto = nil
        isPlayingLivePhoto = false
        let requestID = UUID()
        activeRequestID = requestID
        isLoading = true
        progress = 0
        statusMessage = ""
        requestTask = Task { @MainActor in
            do {
                let size = CGSize(width: max(500, paneSize.width * backingScale), height: max(500, paneSize.height * backingScale))
                let result = try await viewModel.inspectionImage(
                    for: assetID,
                    targetSize: size,
                    maximumSize: maximumSize,
                    progress: { value in
                        guard activeRequestID == requestID else { return }
                        progress = value
                    }
                )
                guard !Task.isCancelled, activeRequestID == requestID else { return }
                image = result
                isMaximumSizeLoaded = maximumSize
                showAtActualSize = maximumSize
                zoomResetID = UUID()
                isLoading = false
                statusMessage = ""
                activeRequestID = nil
            } catch is CancellationError {
                guard activeRequestID == requestID else { return }
                isLoading = false
                activeRequestID = nil
            } catch {
                guard activeRequestID == requestID else { return }
                isLoading = false
                statusMessage = "Could not load this Photos rendition: \(error.localizedDescription)"
                activeRequestID = nil
            }
        }
    }

    private func requestLivePhoto(in paneSize: CGSize) {
        cancelRequest(clearMedia: false)
        let requestID = UUID()
        activeRequestID = requestID
        isLoading = true
        progress = 0
        statusMessage = ""
        requestTask = Task { @MainActor in
            do {
                let photo = try await viewModel.inspectionLivePhoto(
                    for: assetID,
                    targetSize: CGSize(width: max(500, paneSize.width * backingScale), height: max(500, paneSize.height * backingScale)),
                    progress: { value in
                        guard activeRequestID == requestID else { return }
                        progress = value
                    }
                )
                guard !Task.isCancelled, activeRequestID == requestID else { return }
                livePhoto = photo
                isPlayingLivePhoto = true
                isLoading = false
                activeRequestID = nil
            } catch is CancellationError {
                guard activeRequestID == requestID else { return }
                isLoading = false
                activeRequestID = nil
            } catch {
                guard activeRequestID == requestID else { return }
                isLoading = false
                statusMessage = "Could not load the Live Photo: \(error.localizedDescription)"
                activeRequestID = nil
            }
        }
    }

    private func requestVideo(in paneSize: CGSize) {
        cancelRequest(clearMedia: false)
        let requestID = UUID()
        activeRequestID = requestID
        isLoading = true
        progress = 0
        statusMessage = ""
        requestTask = Task { @MainActor in
            let result = await viewModel.previewPlayerResult(for: assetID) { value in
                guard activeRequestID == requestID else { return }
                progress = value
            }
            guard !Task.isCancelled, activeRequestID == requestID else { return }
            switch result {
            case .ready(let loadedPlayer, let retainedResource):
                player = loadedPlayer
                playerResourceLease = retainedResource
                isLoading = false
                activeRequestID = nil
            case .unavailable(let message):
                isLoading = false
                statusMessage = message
                activeRequestID = nil
            }
        }
        self.paneSize = paneSize
    }

    private func cancelRequest(clearMedia: Bool = false) {
        let wasLoading = isLoading
        requestTask?.cancel()
        requestTask = nil
        activeRequestID = nil
        isLoading = false
        if wasLoading && !clearMedia {
            statusMessage = "Download cancelled. The current photo preview is still available."
        }
        if clearMedia {
            player?.pause()
            player = nil
            playerResourceLease = nil
            livePhoto = nil
            image = nil
            isMaximumSizeLoaded = false
            isPlayingLivePhoto = false
        }
    }
}

@MainActor
private struct ZoomableInspectionImage: View {
    let image: NSImage
    let initiallyAtActualSize: Bool
    let resetID: UUID
    let backingScale: CGFloat

    @State private var zoom = 1.0
    @State private var lastZoom = 1.0
    @State private var offset = CGSize.zero
    @State private var lastOffset = CGSize.zero

    var body: some View {
        GeometryReader { geometry in
            let fitSize = fittedSize(imageSize: image.size, in: geometry.size)
            let actualScale = actualSizeScale(fitSize: fitSize)
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect((initiallyAtActualSize ? actualScale : 1) * zoom)
                .offset(offset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in zoom = min(8, max(1, lastZoom * value)) }
                        .onEnded { _ in lastZoom = zoom }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            guard zoom > 1.01 || initiallyAtActualSize else { return }
                            offset = CGSize(width: lastOffset.width + value.translation.width, height: lastOffset.height + value.translation.height)
                        }
                        .onEnded { _ in lastOffset = offset }
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .onChange(of: resetID) { _, _ in
                    zoom = 1
                    lastZoom = 1
                    offset = .zero
                    lastOffset = .zero
                }
        }
        .accessibilityLabel("Photo inspection image. Pinch or drag to inspect details.")
    }

    private func fittedSize(imageSize: CGSize, in container: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else { return container }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private func actualSizeScale(fitSize: CGSize) -> CGFloat {
        let representation = image.representations.first(where: { $0.pixelsWide > 0 && $0.pixelsHigh > 0 })
        let pixelsWide = CGFloat(representation?.pixelsWide ?? Int(image.size.width))
        let pixelsHigh = CGFloat(representation?.pixelsHigh ?? Int(image.size.height))
        return max(
            1,
            max(
                pixelsWide / max(1, fitSize.width * backingScale),
                pixelsHigh / max(1, fitSize.height * backingScale)
            )
        )
    }
}

private struct AppKitLivePhotoView: NSViewRepresentable {
    let livePhoto: PHLivePhoto
    let isPlaying: Bool

    func makeNSView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView(frame: .zero)
        view.contentMode = .aspectFit
        view.livePhoto = livePhoto
        if isPlaying { view.startPlayback(with: .full) }
        return view
    }

    func updateNSView(_ view: PHLivePhotoView, context: Context) {
        if view.livePhoto !== livePhoto { view.livePhoto = livePhoto }
        if isPlaying { view.startPlayback(with: .full) }
        else { view.stopPlayback(animated: false) }
    }

    static func dismantleNSView(_ view: PHLivePhotoView, coordinator: ()) {
        view.stopPlayback(animated: false)
        view.livePhoto = nil
    }
}
