import AppKit
import SwiftUI

struct AssetCardView: View {
    @EnvironmentObject private var viewModel: ReviewViewModel

    let group: ReviewGroup
    let assetID: String
    let isKept: Bool
    let isHighlighted: Bool
    let imageHeight: CGFloat
    let onSelected: () -> Void

    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(red: 0.91, green: 0.95, blue: 1.0).opacity(0.55))

                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    } else {
                        ProgressView()
                    }
                }
                .frame(height: imageHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                HStack(alignment: .top) {
                    mediaBadgeStrip
                    Spacer()
                    statusBadge
                }
                .padding(8)
            }

            HStack {
                Button("Keep only this") {
                    viewModel.keepOnly(assetID: assetID, in: group)
                }
                .buttonStyle(.bordered)
                .font(.caption)

                Spacer()

                Text(isKept ? "Keeping" : "Discard")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isKept ? .green : .red)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.985, green: 0.99, blue: 1.0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isKept ? Color.green.opacity(0.6) : Color.red.opacity(0.7), lineWidth: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(isHighlighted ? 0.95 : 0), lineWidth: isHighlighted ? 4 : 0)
        )
        .shadow(color: isHighlighted ? Color.accentColor.opacity(0.28) : .clear, radius: isHighlighted ? 8 : 0)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            onSelected()
            viewModel.toggleKeep(assetID: assetID, in: group)
        }
        .onHover { hovering in
            if hovering {
                onSelected()
            }
        }
        .task(id: "\(assetID)-\(Int(imageHeight))") {
            let side = max(320, imageHeight * 1.6)
            if let quick = await viewModel.thumbnail(
                for: assetID,
                side: side,
                deliveryMode: .opportunistic
            ) {
                image = quick
            }

            if let highQuality = await viewModel.thumbnail(
                for: assetID,
                side: side,
                deliveryMode: .highQualityFormat
            ) {
                image = highQuality
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
    private var mediaBadgeStrip: some View {
        let badges = viewModel.mediaBadges(for: assetID)
        if badges.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 4) {
                ForEach(badges, id: \.self) { badge in
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
}
