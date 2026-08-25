import SwiftUI

@main
struct MediaMemoryApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        // The background coordinator and current browsing/search state are one
        // coherent application session. Use a single window instead of letting
        // multiple windows cancel each other's selection or query tasks.
        Window("Media Memory", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1_180, height: 760)
    }
}
