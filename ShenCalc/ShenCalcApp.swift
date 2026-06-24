import SwiftUI

@main
struct ShenCalcApp: App {
    @StateObject private var cas = ShenCAS()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(cas)
                .preferredColorScheme(.dark)
        }
    }
}

/// Top-level shell: the symbolic calculator and the adaptive tutor as two tabs,
/// both sharing the single embedded `ShenCAS` engine from the environment.
struct RootView: View {
    private let accent = Color(red: 0.45, green: 0.85, blue: 0.72)

    var body: some View {
        TabView {
            ContentView()
                .tabItem { Label("Calculator", systemImage: "function") }
            TutorRootView()
                .tabItem { Label("Learn", systemImage: "graduationcap") }
        }
        .tint(accent)
    }
}
