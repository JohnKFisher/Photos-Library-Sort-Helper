import AppKit
import SwiftUI

struct AssetCardView: View {
    @EnvironmentObject private var viewModel: ReviewViewModel
    @Environment(\.colorScheme) private var colorScheme

    let group: ReviewGroup
    let assetID: String
    let isKept: Bool
    let isHighlighted: Bool
    let imageHeight: CGFloat
    let onSelected: () -> Void

    @State private var image: NSImage?
    @State private var imageRevision = 0

    var body: some View {
        let cardBackground = UITheme.cardBackground(for: colorScheme, isHighlighted: isHighlighted)
        let keepDiscardBorder = isKept ? UITheme.keep.opacity(0.82) : UITheme.discard.opacity(0.84)
        let highlightScale: CGFloat = isHighlighted ? 1.01 : 1.0
        let highlightShadow: Color = isHighlighted ? Color.accentColor.opacity(0.22) : .clear

        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(UITheme.cardImageBackground(for: colorScheme))

                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            .id(imageRevision)
                            .transition(.opacity)
                    } else {
                        ProgressView()
                            .accessibilityLabel("Loading thumbnail")
                    }
                }
                .frame(height: imageHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .animation(.easeInOut(duration: 0.20), value: imageRevision)

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
                .accessibilityLabel("Keep only this item")
                .accessibilityHint("Marks the selected asset as the only kept item in this group.")

                Spacer()

                Text(isKept ? "Keeping" : "Discard")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isKept ? UITheme.keep : UITheme.discard)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(keepDiscardBorder, lineWidth: 2)
        )
        .overlay(alignment: .leading) {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 5)
                    .padding(.vertical, 8)
                    .padding(.leading, 3)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(isHighlighted ? 0.85 : 0), lineWidth: isHighlighted ? 3 : 0)
        )
        .shadow(color: highlightShadow, radius: isHighlighted ? 10 : 0)
        .scaleEffect(highlightScale)
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: isHighlighted)
        .animation(.easeInOut(duration: 0.16), value: isKept)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Review item")
        .accessibilityValue(isKept ? "Marked to keep" : "Marked to discard")
        .accessibilityHint("Click to toggle keep or discard. Use arrow keys to move the highlight.")
        .onTapGesture {
            onSelected()
            viewModel.toggleKeep(assetID: assetID, in: group)
        }
        .onHover { hovering in
            if hovering && viewModel.shouldAcceptHoverHighlight() {
                onSelected()
            }
        }
        .contextMenu {
            Button("Keep Only This") {
                viewModel.keepOnly(assetID: assetID, in: group)
            }

            Button(isKept ? "Mark Discard" : "Mark Keep") {
                viewModel.toggleKeep(assetID: assetID, in: group)
            }

            Button("Queue For Edit") {
                onSelected()
                viewModel.queueHighlightedAssetForEditingInCurrentGroup()
            }

            if viewModel.canRevealItemInFinder(assetID: assetID) {
                Divider()

                Button("Reveal In Finder") {
                    viewModel.revealItemInFinder(assetID: assetID)
                }
            }
        }
        .task(id: "\(assetID)-\(Int(imageHeight))") {
            let side = max(320, imageHeight * 1.6)
            if let quick = await viewModel.thumbnail(
                for: assetID,
                side: side,
                deliveryMode: .opportunistic
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    image = quick
                    imageRevision += 1
                }
            }

            if let highQuality = await viewModel.thumbnail(
                for: assetID,
                side: side,
                deliveryMode: .highQualityFormat
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    image = highQuality
                    imageRevision += 1
                }
            }
        }
    }

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
                        .background(UITheme.mediaBadgeBackground)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
        }
    }
}
