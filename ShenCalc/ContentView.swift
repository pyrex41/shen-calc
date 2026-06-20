import SwiftUI
import PhotosUI

struct Entry: Identifiable {
    let id = UUID()
    let input: String     // what the user asked (NL or syntax)
    let cas: String       // the shen-cas syntax actually evaluated
    let result: String    // the normal form
    var isError: Bool { result.hasPrefix("error:") }
}

enum InputMode: String, CaseIterable, Identifiable {
    case syntax = "Syntax"
    case english = "English"
    case photo = "Photo"
    var id: String { rawValue }
    var needsModel: Bool { self != .syntax }
    var placeholder: String {
        switch self {
        case .syntax: return "e.g. D[Sin[x], x]"
        case .english: return "e.g. derivative of sin x"
        case .photo: return "describe, or just attach a photo"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var cas: ShenCAS
    private let passthrough = PassthroughInterpreter()
    @State private var nl: MathInterpreter? = nil

    @State private var entries: [Entry] = []
    @State private var input = ""
    @State private var mode: InputMode = .syntax
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var working = false
    @FocusState private var inputFocused: Bool
    @StateObject private var fieldController = MathFieldController()

    private let examples = ["D[Sin[x], x]", "Integrate[x^2, x]", "Factor[x^2 - 1]",
                            "Solve[x^2 - 4, x]", "Expand[(x+1)^2]", "6/4"]
    private let accent = Color(red: 0.45, green: 0.85, blue: 0.72)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            transcript
            composer
        }
        .background(Color(red: 0.06, green: 0.07, blue: 0.09).ignoresSafeArea())
        .onAppear { if nl == nil { nl = NLEngine.make() } }
        .onChange(of: cas.isReady) { ready in
            guard ready else { return }
            let env = ProcessInfo.processInfo.environment
            if env["SHENCALC_SELFTEST"] != nil { Task { await runSelfTest() } }
            if entries.isEmpty, env["SHENCALC_DEMO"] != nil { Task { await seedDemo() } }
        }
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task { photoData = try? await item.loadTransferable(type: Data.self) }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("shen").fontWeight(.heavy)
            Text("·calc").foregroundStyle(accent).fontWeight(.heavy)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(cas.isReady ? accent : .orange).frame(width: 7, height: 7)
                Text(cas.isReady ? "engine ready" : "starting…")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .font(.title2)
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if entries.isEmpty { emptyState }
                    ForEach(entries) { card($0) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16).padding(.top, 14)
            }
            .onChange(of: entries.count) { _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A symbolic calculator — the math runs in a tree-shaken Shen CAS embedded in Rust, on device.")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("Try").font(.caption).foregroundStyle(.tertiary)
            FlowChips(items: examples, accent: accent) { mode = .syntax; input = $0; submit() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 30)
    }

    private func card(_ e: Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(e.input)
                .font(.system(.body, design: .monospaced)).foregroundStyle(.white)
            if e.cas != e.input {
                Text("→ \(e.cas)")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
            }
            HStack(alignment: .top, spacing: 8) {
                Text("=").foregroundStyle(accent).fontWeight(.bold)
                Text(e.result)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(e.isError ? .red : accent)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06)))
    }

    private var composer: some View {
        VStack(spacing: 8) {
            Picker("Mode", selection: $mode) {
                ForEach(InputMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if mode.needsModel && !NLEngine.available {
                Text("On-device model not enabled — add the mlx-swift-lm package and run on a device. Syntax mode works now.")
                    .font(.caption2).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                if mode == .photo {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Image(systemName: photoData == nil ? "photo" : "checkmark.circle.fill")
                            .frame(width: 42, height: 42)
                            .background(Color.white.opacity(0.06), in: Circle())
                            .foregroundStyle(photoData == nil ? .secondary : accent)
                    }
                }
                CaretTextField(text: $input,
                               placeholder: mode.placeholder,
                               useMathKeyboard: mode == .syntax,
                               accent: accent,
                               controller: fieldController,
                               onSubmit: submit)
                    .frame(height: 24)
                    .focused($inputFocused)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(Color.white.opacity(0.06), in: Capsule())
                Button(action: submit) {
                    Image(systemName: working ? "ellipsis" : "arrow.up")
                        .fontWeight(.bold).frame(width: 42, height: 42)
                        .background(canSubmit ? accent : Color.gray.opacity(0.3), in: Circle())
                        .foregroundStyle(.black)
                }
                .disabled(!canSubmit)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var canSubmit: Bool {
        guard cas.isReady, !working else { return false }
        if mode.needsModel && !NLEngine.available { return false }
        if mode == .photo { return photoData != nil || !input.trimmingCharacters(in: .whitespaces).isEmpty }
        return !input.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let img = photoData
        let m = mode
        input = ""; photoData = nil; photoItem = nil; working = true
        Task {
            let interp: MathInterpreter = m.needsModel ? (nl ?? passthrough) : passthrough
            let casExpr: String
            do {
                casExpr = try await interp.toCAS(text: raw, imageData: img)
            } catch {
                entries.append(Entry(input: raw.isEmpty ? "[image]" : raw, cas: "",
                                     result: "error: \(error.localizedDescription)"))
                working = false; return
            }
            let result = MathPretty.render(await cas.reduce(casExpr))
            let shown = raw.isEmpty ? "[image]" : raw
            entries.append(Entry(input: shown, cas: casExpr, result: result))
            working = false
        }
    }

    private func seedDemo() async {
        for expr in ["D[Sin[x], x]", "Integrate[x^2, x]", "Factor[x^2 - 1]", "Expand[(x+1)^2]"] {
            let result = MathPretty.render(await cas.reduce(expr))
            entries.append(Entry(input: expr, cas: expr, result: result))
        }
    }

    /// Headless smoke test of every operation, gated by SHENCALC_SELFTEST.
    /// Prints raw CAS output + the human-readable render so the simulator console
    /// shows exactly what each op produces (and surfaces any crash).
    private func runSelfTest() async {
        print("=== SHENCALC SELFTEST START ===")
        let cases = [
            "D[Sin[x], x]", "D[Cos[x], x]", "D[Tan[x], x]", "D[Exp[x], x]",
            "D[Log[x], x]", "D[Sqrt[x], x]", "D[x^3, x]",
            "Integrate[x^2, x]", "Integrate[Sin[x], x]", "Integrate[1/x, x]",
            "Simplify[a + a]", "Expand[(x+1)^2]", "Expand[(x+1)*(x-1)]",
            "Factor[x^2 - 1]", "Factor[x^2 + 2*x + 1]",
            "Solve[x^2 - 4, x]", "6/4", "2^10", "a+b*c", "Sin[0]",
        ]
        for c in cases {
            let raw = await cas.reduce(c)
            print("CASE \(c)  =>  raw=\(raw)  pretty=\(MathPretty.render(raw))")
        }
        // Tool-call parser checks (no model needed).
        let toolChecks = [
            "INTEGRATE(x^2; x)", "D(Sin[x]; x)", "FACTOR(x^2 - 1)",
            "SOLVE(x^2 - 4; x)", "EVAL(2 + 3)", "integrate(sin(x); x)",
        ]
        for t in toolChecks { print("TOOL \(t)  =>  \(CASTools.parse(t))") }
        print("=== SHENCALC SELFTEST DONE ===")
    }
}

/// Simple wrapping chip row for the example prompts.
struct FlowChips: View {
    let items: [String]
    let accent: Color
    let tap: (String) -> Void
    var body: some View {
        FlexibleWrap(items, spacing: 8) { item in
            Button { tap(item) } label: {
                Text(item)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(accent.opacity(0.14), in: Capsule())
                    .foregroundStyle(accent)
            }
        }
    }
}

/// Minimal flow layout (iOS 16-compatible) for the chips.
struct FlexibleWrap<Data: RandomAccessCollection, Content: View>: View where Data.Element: Hashable {
    let data: Data
    let spacing: CGFloat
    let content: (Data.Element) -> Content
    init(_ data: Data, spacing: CGFloat = 8, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data; self.spacing = spacing; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: spacing) { ForEach(row, id: \.self) { content($0) } }
            }
        }
    }
    private var rows: [[Data.Element]] {
        var out: [[Data.Element]] = []; var cur: [Data.Element] = []
        for item in data { cur.append(item); if cur.count == 2 { out.append(cur); cur = [] } }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
