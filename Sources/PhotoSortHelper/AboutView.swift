import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 92, height: 92)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(AppMetadata.displayName)
                    .font(.title2.weight(.semibold))

                Text(AppMetadata.releaseLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(AppMetadata.copyrightNotice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text(AppMetadata.aboutSummary)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            Link("View project on GitHub", destination: AppMetadata.repositoryURL)
                .font(.body.weight(.semibold))
        }
        .padding(28)
        .frame(width: 460)
        .containerBackground(.thickMaterial, for: .window)
    }
}
