import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var consoleRegistered = false

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        if consoleRegistered {
            let console = ConsoleMailbox(home: FileManager.default.homeDirectoryForCurrentUser)
            _ = try? console.register(event: "end", timeout: 1)
        }
    }
}

struct ReasonNetworkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = NetworkModel()
    var body: some Scene {
        Window("Reason Network", id: "main") {
            ContentView().environmentObject(model)
                .onChange(of: model.consoleAddress, initial: true) { _, address in
                    if address != nil { delegate.consoleRegistered = true }
                }
        }
        .defaultSize(width: 760, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appSettings) {
                Button("设置…") { model.open(.settings) }.keyboardShortcut(",")
            }
            CommandMenu("显示") {
                Button("概览") { model.open(.overview) }.keyboardShortcut("1")
                Button("会话目录") { model.open(.sessions) }.keyboardShortcut("2")
                Button("消息") { model.showsUtilities = false }.keyboardShortcut("3")
                Button("设置") { model.open(.settings) }.keyboardShortcut("4")
                Divider()
                Button("刷新") { Task { await model.refresh() } }.keyboardShortcut("r")
            }
        }
    }
}

@main
enum ReasonNetworkLauncher {
    @MainActor static func main() {
        guard CommandLine.arguments.contains("--self-test") else {
            ReasonNetworkApp.main()
            return
        }
        Task.detached {
            do {
                let result = try await ReasonService().selfTest()
                print(String(decoding: result, as: UTF8.self))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(1)
            }
        }
        dispatchMain()
    }
}
