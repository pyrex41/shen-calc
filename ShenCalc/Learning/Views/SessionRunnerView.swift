import SwiftUI

/// Minimal practice-session runner UI.
///
/// Drives one `LearningSession`: shows the rendered prompt, accepts an answer via
/// the existing `CaretTextField` / `MathKeyboard`, grades on submit, shows
/// correctness feedback (plus any "you unlocked X" moment), and advances to the
/// next slot. Deliberately spare — it owns no scheduling/grading logic; everything
/// load-bearing lives in `LearningSession`.
///
/// Construct it with a ready `LearningSession`; the view `start()`s the session on
/// appear. The same view serves placement sessions (the runner just collects the
/// correct nodes and calls `completePlacement` at the end).
struct SessionRunnerView: View {

    @StateObject private var session: LearningSession

    /// Composer field controller, shared with the math keyboard (iOS) so taps land
    /// at the caret. On macOS this is a no-op shim (see MathKeyboard.swift).
    @StateObject private var fieldController = MathFieldController()

    /// Correctly-answered nodes accumulated during a placement session, replayed
    /// into `completePlacement` when the session finishes.
    @State private var placementCorrect: [NodeID] = []

    private let accent = Color(red: 0.45, green: 0.85, blue: 0.72)
    private let background = Color(red: 0.06, green: 0.07, blue: 0.09)

    init(session: LearningSession) {
        _session = StateObject(wrappedValue: session)
    }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            content
                .padding(.horizontal, 20)
        }
        .task { await session.start() }
    }

    // MARK: - Phase switch

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .loading:
            ProgressView().tint(accent)
        case .presenting, .graded:
            VStack(alignment: .leading, spacing: 18) {
                header
                problemCard
                stepsSection
                Spacer(minLength: 0)
                composer
                feedbackBar
            }
            .padding(.vertical, 24)
        case .finished:
            finishedView
        case .failed(let message):
            failedView(message)
        }
    }

    // MARK: - Header / progress

    private var header: some View {
        HStack {
            Text(session.isPlacement ? "Placement" : "Practice")
                .font(.headline).foregroundStyle(.white)
            Spacer()
            Text("\(session.slotNumber) / \(session.slotCount)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Problem

    @ViewBuilder
    private var problemCard: some View {
        if let p = session.current {
            VStack(alignment: .leading, spacing: 10) {
                Text(p.directive.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                Text(p.prompt)
                    .font(.system(.title2, design: .serif))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - Verified worked steps

    /// Progressive hint UI: each tap reveals one more *verified* rewrite step
    /// (last step is provably the engine's normal form). Empty until requested.
    @ViewBuilder
    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(session.revealedSteps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(i + 1).")
                        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.afterPretty)
                            .font(.system(.subheadline, design: .serif)).foregroundStyle(.white)
                        Text(step.why)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if session.current != nil {
                if session.noStepsAvailable {
                    Label("No steps to show", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                } else if session.revealedSteps.isEmpty || session.moreStepsAvailable {
                    Button {
                        Task { await session.requestHint() }
                    } label: {
                        Label(session.revealedSteps.isEmpty ? "Show steps" : "Next step",
                              systemImage: "lightbulb")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.default, value: session.revealedSteps.count)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 12) {
            CaretTextField(
                text: $session.input,
                placeholder: "your answer",
                useMathKeyboard: true,
                accent: accent,
                controller: fieldController,
                onSubmit: { Task { await session.submit() } })
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

            Button {
                Task { await session.submit() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(width: 48, height: 48)
                    .background(canSubmit ? accent : Color.gray.opacity(0.3), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
        }
    }

    private var canSubmit: Bool {
        guard case .presenting = session.phase else { return false }
        return !session.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Feedback

    @ViewBuilder
    private var feedbackBar: some View {
        if case .graded(let verdict) = session.phase, let result = session.lastResult {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(session.justUnlocked) { node in
                    Label("You unlocked \(node.name)", systemImage: "lock.open.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(accent)
                }
                HStack(spacing: 10) {
                    Image(systemName: icon(for: verdict))
                        .foregroundStyle(color(for: verdict))
                    Text(result.message)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                    Spacer()
                    Button("Next") { Task { await advance(after: verdict) } }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(accent, in: Capsule())
                        .buttonStyle(.plain)
                }
            }
            .padding(14)
            .background(color(for: verdict).opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        } else {
            // Reserve a little space so the layout doesn't jump on grade.
            Color.clear.frame(height: 1)
        }
    }

    private func advance(after verdict: GradeResult.Verdict) async {
        if session.isPlacement, verdict == .correct, let node = session.current?.skill {
            placementCorrect.append(node)
        }
        await session.advance()
        if case .finished = session.phase, session.isPlacement {
            session.completePlacement(correctNodes: placementCorrect)
        }
    }

    private func icon(for v: GradeResult.Verdict) -> String {
        switch v {
        case .correct:             return "checkmark.circle.fill"
        case .incorrect:           return "xmark.circle.fill"
        case .rightValueWrongForm: return "exclamationmark.triangle.fill"
        case .malformed:           return "questionmark.circle.fill"
        }
    }

    private func color(for v: GradeResult.Verdict) -> Color {
        switch v {
        case .correct:             return accent
        case .incorrect:           return .red
        case .rightValueWrongForm: return .orange
        case .malformed:           return .yellow
        }
    }

    // MARK: - Terminal states

    private var finishedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48)).foregroundStyle(accent)
            Text("Session complete")
                .font(.title2.weight(.semibold)).foregroundStyle(.white)
            Text("\(session.correctCount) of \(session.slotCount) correct")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40)).foregroundStyle(.orange)
            Text(message)
                .font(.subheadline).foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
    }
}
