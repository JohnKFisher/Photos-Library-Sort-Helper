@preconcurrency import AVFoundation
@preconcurrency import Photos
@preconcurrency import PhotosUI
import SwiftUI
import UIKit

@MainActor
enum PhotoKitMediaLoader {
    private static let imageManager = PHCachingImageManager()

    static func image(
        for asset: PHAsset,
        targetSize: CGSize,
        deliveryMode: PHImageRequestOptionsDeliveryMode,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> UIImage? {
        let relay = MediaRequestLatch<UIImage> { imageManager.cancelImageRequest($0) }
        let result: MediaValueBox<UIImage>? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                relay.install(continuation)
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = deliveryMode
                options.resizeMode = deliveryMode == .opportunistic ? .fast : .exact
                options.progressHandler = { fraction, _, _, _ in progress?(fraction) }
                let id = imageManager.requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: .aspectFit,
                    options: options
                ) { image, info in
                    if info?[PHImageCancelledKey] as? Bool == true || info?[PHImageErrorKey] != nil {
                        relay.finish(nil)
                    } else if info?[PHImageResultIsDegradedKey] as? Bool != true {
                        relay.finish(image)
                    }
                }
                relay.setRequestID(id)
            }
        } onCancel: {
            relay.cancel()
        }
        return result?.value
    }

    static func livePhoto(
        for asset: PHAsset,
        targetSize: CGSize,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> PHLivePhoto? {
        let relay = MediaRequestLatch<PHLivePhoto> { imageManager.cancelImageRequest($0) }
        let result: MediaValueBox<PHLivePhoto>? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                relay.install(continuation)
                let options = PHLivePhotoRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .highQualityFormat
                options.progressHandler = { fraction, _, _, _ in progress?(fraction) }
                let id = imageManager.requestLivePhoto(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: .aspectFit,
                    options: options
                ) { livePhoto, info in
                    if info?[PHImageCancelledKey] as? Bool == true || info?[PHImageErrorKey] != nil {
                        relay.finish(nil)
                    } else if info?[PHImageResultIsDegradedKey] as? Bool != true {
                        relay.finish(livePhoto)
                    }
                }
                relay.setRequestID(id)
            }
        } onCancel: {
            relay.cancel()
        }
        return result?.value
    }

    static func video(
        for asset: PHAsset,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> AVAsset? {
        let relay = MediaRequestLatch<AVAsset> { imageManager.cancelImageRequest($0) }
        let result: MediaValueBox<AVAsset>? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                relay.install(continuation)
                let options = PHVideoRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .highQualityFormat
                options.progressHandler = { fraction, _, _, _ in progress?(fraction) }
                let id = imageManager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                    if info?[PHImageCancelledKey] as? Bool == true || info?[PHImageErrorKey] != nil {
                        relay.finish(nil)
                    } else {
                        relay.finish(avAsset)
                    }
                }
                relay.setRequestID(id)
            }
        } onCancel: {
            relay.cancel()
        }
        return result?.value
    }
}

private struct MediaValueBox<Value>: @unchecked Sendable {
    let value: Value
}

private final class MediaRequestLatch<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelRequest: (PHImageRequestID) -> Void
    private var continuation: CheckedContinuation<MediaValueBox<Value>?, Never>?
    private var requestID: PHImageRequestID?
    private var cancelled = false
    private var finished = false

    init(cancelRequest: @escaping (PHImageRequestID) -> Void) {
        self.cancelRequest = cancelRequest
    }

    func install(_ continuation: CheckedContinuation<MediaValueBox<Value>?, Never>) {
        lock.lock()
        let shouldFinish = cancelled || finished
        if !shouldFinish { self.continuation = continuation }
        lock.unlock()
        if shouldFinish { continuation.resume(returning: nil) }
    }

    func setRequestID(_ id: PHImageRequestID) {
        lock.lock()
        let shouldCancel = cancelled || finished
        if !shouldCancel { requestID = id }
        lock.unlock()
        if shouldCancel { cancelRequest(id) }
    }

    func finish(_ value: Value?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        self.requestID = nil
        lock.unlock()
        continuation?.resume(returning: value.map(MediaValueBox.init))
    }

    func cancel() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        cancelled = true
        let id = requestID
        requestID = nil
        lock.unlock()
        if let id { cancelRequest(id) }
        finish(nil)
    }
}

@MainActor
struct LivePhotoMediaView: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    var startsPlayback = false

    func makeUIView(context: Context) -> PHLivePhotoView {
        PHLivePhotoView()
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        view.livePhoto = livePhoto
        if startsPlayback { view.startPlayback(with: .full) } else { view.stopPlayback() }
    }
}
