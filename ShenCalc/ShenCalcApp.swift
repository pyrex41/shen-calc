import SwiftUI

@main
struct ShenCalcApp: App {
    @StateObject private var cas = ShenCAS()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(cas)
                .preferredColorScheme(.dark)
        }
    }
}
