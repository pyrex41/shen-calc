import SwiftUI
import UIKit

// A custom on-screen math keyboard for shen-cas syntax. It is installed as the
// `inputView` of the composer's text field, so it replaces the system keyboard
// when typing syntax — tapping a key inserts at the caret and positions the
// cursor inside brackets, the way a real calculator would.
//
// Only operations that the embedded CAS actually evaluates are exposed (verified
// against shen_cas_reduce): D, Integrate, Simplify, Expand, Factor, Solve and
// the Sin/Cos/Tan/Exp/Log/Sqrt functions. Series/Limit echo unevaluated, so they
// are intentionally omitted.

/// Bridges SwiftUI key taps to the underlying UITextField caret operations.
final class MathFieldController: ObservableObject {
    fileprivate weak var field: UITextField?
    var onSubmit: () -> Void = {}

    /// Insert `text` at the caret, then move the caret left by `caretBack`
    /// characters (so `Sin[]` lands the cursor between the brackets).
    func insert(_ text: String, caretBack: Int = 0) {
        guard let field, let range = field.selectedTextRange else { return }
        field.replace(range, withText: text)
        if caretBack > 0,
           let start = field.selectedTextRange?.start,
           let pos = field.position(from: start, offset: -caretBack) {
            field.selectedTextRange = field.textRange(from: pos, to: pos)
        }
        field.sendActions(for: .editingChanged)
    }

    func deleteBackward() {
        field?.deleteBackward()
        field?.sendActions(for: .editingChanged)
    }

    func clear() {
        field?.text = ""
        field?.sendActions(for: .editingChanged)
    }

    func submit() { onSubmit() }
}

/// A UITextField whose `inputView` is the SwiftUI math keyboard (in syntax mode)
/// or the system keyboard (in English/Photo mode).
struct CaretTextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let useMathKeyboard: Bool
    let accent: Color
    let controller: MathFieldController
    let onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.delegate = context.coordinator
        tf.placeholder = placeholder
        tf.autocorrectionType = .no
        tf.autocapitalizationType = .none
        tf.smartQuotesType = .no
        tf.smartDashesType = .no
        tf.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        tf.textColor = .white
        tf.tintColor = UIColor(accent)
        tf.returnKeyType = .go
        tf.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        controller.field = tf
        controller.onSubmit = onSubmit
        context.coordinator.installKeyboard(on: tf, useMath: useMathKeyboard)
        return tf
    }

    func updateUIView(_ tf: UITextField, context: Context) {
        if tf.text != text { tf.text = text }
        tf.placeholder = placeholder
        controller.field = tf
        controller.onSubmit = onSubmit
        if context.coordinator.usingMath != useMathKeyboard {
            context.coordinator.installKeyboard(on: tf, useMath: useMathKeyboard)
            if tf.isFirstResponder { tf.reloadInputViews() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        let parent: CaretTextField
        var usingMath = false
        private var host: UIHostingController<MathKeyboard>?

        init(_ parent: CaretTextField) { self.parent = parent }

        func installKeyboard(on tf: UITextField, useMath: Bool) {
            usingMath = useMath
            guard useMath else { tf.inputView = nil; return }
            let kb = MathKeyboard(controller: parent.controller, accent: parent.accent)
            let h = UIHostingController(rootView: kb)
            h.view.backgroundColor = UIColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1)
            h.view.translatesAutoresizingMaskIntoConstraints = true
            h.view.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 292)
            h.view.autoresizingMask = [.flexibleWidth]
            host = h
            tf.inputView = h.view
        }

        @objc func editingChanged(_ tf: UITextField) {
            parent.text = tf.text ?? ""
        }

        func textFieldShouldReturn(_ tf: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}

// MARK: - Keyboard layout

private struct Key: Identifiable {
    let id = UUID()
    let label: String
    let insert: String
    let caretBack: Int
    var kind: Kind = .normal
    enum Kind { case normal, accent, function, action }
}

struct MathKeyboard: View {
    let controller: MathFieldController
    let accent: Color

    // Functions / calculus — horizontal scroll of accent keys. Each inserts a
    // template and drops the caret where the user types next.
    private let functions: [Key] = [
        Key(label: "d/dx", insert: "D[, x]", caretBack: 4, kind: .function),
        Key(label: "∫ dx", insert: "Integrate[, x]", caretBack: 4, kind: .function),
        Key(label: "Solve", insert: "Solve[, x]", caretBack: 4, kind: .function),
        Key(label: "Simplify", insert: "Simplify[]", caretBack: 1, kind: .function),
        Key(label: "Expand", insert: "Expand[]", caretBack: 1, kind: .function),
        Key(label: "Factor", insert: "Factor[]", caretBack: 1, kind: .function),
        Key(label: "sin", insert: "Sin[]", caretBack: 1, kind: .function),
        Key(label: "cos", insert: "Cos[]", caretBack: 1, kind: .function),
        Key(label: "tan", insert: "Tan[]", caretBack: 1, kind: .function),
        Key(label: "eˣ", insert: "Exp[]", caretBack: 1, kind: .function),
        Key(label: "ln", insert: "Log[]", caretBack: 1, kind: .function),
        Key(label: "√", insert: "Sqrt[]", caretBack: 1, kind: .function),
    ]

    // 6-column numeric + operator grid.
    private let grid: [[Key]] = [
        [k("7"), k("8"), k("9"), op("(", "("), op(")", ")"), Key(label: "⌫", insert: "", caretBack: 0, kind: .action)],
        [k("4"), k("5"), k("6"), op("^", "^"), op(",", ", "), Key(label: "clear", insert: "", caretBack: 0, kind: .action)],
        [k("1"), k("2"), k("3"), op("+", " + "), op("−", " - "), Key(label: "↵", insert: "", caretBack: 0, kind: .accent)],
        [k("0"), op(".", "."), k("x"), k("y"), op("×", " * "), op("÷", " / ")],
    ]

    private static func k(_ s: String) -> Key { Key(label: s, insert: s, caretBack: 0) }
    private static func op(_ label: String, _ ins: String) -> Key { Key(label: label, insert: ins, caretBack: 0) }
    private static func op(_ s: String) -> Key { Key(label: s, insert: s, caretBack: 0) }

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(functions) { key in keyButton(key) }
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 44)

            VStack(spacing: 6) {
                ForEach(grid.indices, id: \.self) { r in
                    HStack(spacing: 6) {
                        ForEach(grid[r]) { key in keyButton(key) }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func keyButton(_ key: Key) -> some View {
        Button {
            tap(key)
        } label: {
            Text(key.label)
                .font(key.kind == .function
                      ? .system(.subheadline, design: .rounded).weight(.medium)
                      : .system(.title3, design: .rounded).weight(.medium))
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(maxWidth: key.kind == .function ? nil : .infinity)
                .frame(height: key.kind == .function ? 44 : 50)
                .padding(.horizontal, key.kind == .function ? 14 : 0)
                .foregroundStyle(foreground(key))
                .background(background(key), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }

    private func foreground(_ key: Key) -> Color {
        switch key.kind {
        case .function: return accent
        case .accent: return .black
        case .action: return .white
        case .normal: return .white
        }
    }

    private func background(_ key: Key) -> Color {
        switch key.kind {
        case .function: return accent.opacity(0.16)
        case .accent: return accent
        case .action: return Color.white.opacity(0.10)
        case .normal: return Color.white.opacity(0.07)
        }
    }

    private func tap(_ key: Key) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        switch (key.kind, key.label) {
        case (.action, "⌫"): controller.deleteBackward()
        case (.action, "clear"): controller.clear()
        case (.accent, "↵"): controller.submit()
        default: controller.insert(key.insert, caretBack: key.caretBack)
        }
    }
}
