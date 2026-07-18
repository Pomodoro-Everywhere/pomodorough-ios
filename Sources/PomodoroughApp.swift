import SwiftUI

@main
struct PomodoroughApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { await model.restore() }
                .onOpenURL { GoogleAuthService.handle($0) }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await model.refreshAfterForeground() }
                }
        }
#if os(macOS)
        .defaultSize(width: 920, height: 760)
#endif
    }
}
