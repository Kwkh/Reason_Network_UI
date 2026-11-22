import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
        return true
    }
}
@main
struct ReasonNetworkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = NetworkModel()
    var body: some Scene {
        Window("Reason Network", id: "main") {
            ContentView().environmentObject(model)
        }
        .defaultSize(width: 760, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .toolbar) {
                Button("刷新 Network") { Task { await model.refresh() } }.keyboardShortcut("r")
            }
        }
    }
}
