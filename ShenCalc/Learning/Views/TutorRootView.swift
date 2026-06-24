import SwiftUI

/// Hosts the adaptive tutor (the "Learn" tab). It lazily builds the persistent
/// learner store and the grading client once the view appears, hands them to a
/// `LearningSession`, drives a practice session via `SessionRunnerView`, and
/// offers the `ProgressMapView` as a navigation destination.
///
/// The session is built off the shared `ShenCAS` engine in the environment
/// (injected by `ShenCalcApp`). Problem generation simply `await`s the engine, so
/// it is safe to build the session before the engine reports `isReady` — early
/// reduces queue and resolve once boot completes.
struct TutorRootView: View {
    @EnvironmentObject private var cas: ShenCAS

    /// Built once, on first appearance. `nil` while loading; carries the live
    /// view-model thereafter.
    @State private var session: LearningSession?
    @State private var loadError: String?
    @State private var showProgress = false

    private let accent = Color(red: 0.45, green: 0.85, blue: 0.72)

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    SessionRunnerView(session: session)
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                Button {
                                    showProgress = true
                                } label: {
                                    Label("Progress", systemImage: "map")
                                }
                            }
                        }
                        .navigationDestination(isPresented: $showProgress) {
                            ProgressMapView(graph: .mvp, learner: session.learner)
                                .navigationTitle("Progress")
                        }
                } else if let loadError {
                    errorState(loadError)
                } else {
                    ProgressView("Preparing your session…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Learn")
        }
        .task { await build() }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle).foregroundStyle(.orange)
            Text(message)
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") { loadError = nil; Task { await build() } }
                .foregroundStyle(accent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor
    private func build() async {
        guard session == nil else { return }
        do {
            let store = try LearnerStore.loadOrCreate(graphVersion: "mvp")
            session = LearningSession(graph: .mvp, store: store, cas: CASClient(engine: cas))
        } catch {
            loadError = "Couldn't load your progress: \(error.localizedDescription)"
        }
    }
}
