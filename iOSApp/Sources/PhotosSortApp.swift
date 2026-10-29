import SwiftUI

@main
struct PhotosSortApp: App {
    @StateObject private var model = PhotosReviewModel()

    var body: some Scene {
        WindowGroup {
            PhotosSortRootView()
                .environmentObject(model)
                .task { model.refreshLocalState() }
        }
    }
}

struct PhotosSortRootView: View {
    @EnvironmentObject private var model: PhotosReviewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                switch model.screen {
                case .home:
                    HomeView()
                case .albumBinding:
                    AlbumBindingView()
                case .review:
                    ReviewWorkspaceView()
                case .pending:
                    PendingQueueView()
                case .pendingReview:
                    PendingItemReviewView()
                case .conflicts:
                    ConflictReviewView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Photos Sort Helper").font(.headline)
                }
            }
            .alert("Photos Sort Helper", isPresented: $model.showAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(model.alertMessage)
            }
            .sheet(isPresented: $model.showCommitSummary) {
                CommitSummaryView()
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $model.showInspector) {
                PhotoInspectorSheet()
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $model.isComparing) {
                ComparisonSheet()
                    .presentationDetents([.large])
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let message = model.statusMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(message)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .tint(.orange)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.onForeground() } else { model.onBackground() }
        }
    }
}
