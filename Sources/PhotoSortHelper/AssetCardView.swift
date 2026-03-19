import AppKit
import SwiftUI

struct AssetCardView: View {
    @EnvironmentObject private var viewModel: ReviewViewModel
    @Environment(\.colorScheme) private var colorScheme

    let group: ReviewGroup
    let assetID: String
    let isKept: Bool
    let isSuggestedBest: Bool
    let isSuggestedDiscard: Bool
    let scoreExplanation: String
    let isHighlighted: Bool
    let imageHeight: CGFloat
    let onSelected: () -> Void

    @State private var image: NSImage?
    @State private var imageRevision = 0

    var body: some View {
        let cardBackground = UITheme.cardBackground(for: colorScheme, isHighlighted: isHighlighted)
        let keepDiscardBorder = isKept ? UITheme.keep.opacity(0.82) : UITheme.discard.opacity(0.84)
        let highlightScale: CGFloat = isHighlighted ? 1.01 : 1.0
        let highlightShadow: Color = isHighlighted ? Color.accentColor.opacity(0.45) : .clear

        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(UITheme.cardImageBackground(for: colorScheme).opacity(0.72))

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
                    }
                }
                .frame(height: imageHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .animation(.easeInOut(duration: 0.20), value: imageRevision)

                HStack(alignment: .top) {
                    mediaBadgeStrip
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        if isSuggestedDiscard {
                            discardSuggestionBadge
                        }
                        if isSuggestedBest {
                            bestShotBadge
                        }
                        statusBadge
                    }
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
            highlightRail
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(isHighlighted ? 0.9 : 0), lineWidth: isHighlighted ? 1.5 : 0)
                .padding(1.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(isHighlighted ? 1.0 : 0), lineWidth: isHighlighted ? 5 : 0)
        )
        .shadow(color: highlightShadow, radius: isHighlighted ? 12 : 0)
        .scaleEffect(highlightScale)
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: isHighlighted)
        .animation(.easeInOut(duration: 0.16), value: isKept)
        .help(scoreExplanation)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            onSelected()
            viewModel.toggleKeep(assetID: assetID, in: group)
        }
        .onHover { hovering in
            if hovering {
                if viewModel.shouldAcceptHoverHighlight() {
                    onSelected()
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

    @ViewBuilder
    private var highlightRail: some View {
        if isHighlighted {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor)
                .frame(width: 5)
                .padding(.vertical, 8)
                .padding(.leading, 3)
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
