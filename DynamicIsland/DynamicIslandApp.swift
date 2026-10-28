import SwiftUI
import AppKit

// 平时保持非激活悬浮窗口；编辑时间时允许数字输入框成为键盘焦点。
private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// 管理灵动岛的悬浮面板：创建、配置、显示
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var islandPanel: NSPanel?
    private let islandModel = IslandModel(notes: NotesStore(fileURL: NotesStore.localURL))
    private lazy var sessionMonitor = IslandSessionMonitor(
        onLock: { [weak self] in
            self?.islandModel.setSessionLocked()
            NotesWindow.hideForLock()
        },
        onUnlock: { [weak self] showsGreeting in
            guard let self else { return }
            islandModel.handleSessionUnlock(showsGreeting: showsGreeting &&
                IslandDisplaySettings.shared.snapshot.isEnabled(.unlockGreeting))
        }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 创建「非激活面板」：不需要成为 key window，
        // 所以每次点击都会直接传给视图，不会发生「第一下被拿去激活窗口」的问题
        let panel = IslandPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.becomesKeyOnlyIfNeeded = true
        WindowManager.configure(window: panel)

        // Do not expose content if launched into a locked or inactive session.
        sessionMonitor.start()
        let hostingView = NSHostingView(rootView: ContentView(model: islandModel))
        panel.contentView = hostingView

        islandPanel = panel
        panel.orderFrontRegardless()
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionMonitor.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 菜单栏常驻 app：窗口关了也不要退出
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ScreenRecordingController.shared.isBusy else { return .terminateNow }
        Task { @MainActor in
            await ScreenRecordingController.shared.finishBeforeQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func showGreetingPreview() {
        islandModel.presentUnlockGreeting()
    }
}

@main
struct DynamicIslandApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var recorder = ScreenRecordingController.shared

    var body: some Scene {
        // 菜单栏图标：控制显示/隐藏、退出
        MenuBarExtra("灵动岛", systemImage: "dot.viewfinder") {
            Button("设置…") {
                IslandSettingsWindow.show()
            }
            .keyboardShortcut(",", modifiers: .command)
            if recorder.isCapturing {
                Divider()
                Button(recorder.isPaused ? "继续录屏" : "暂停录屏") { recorder.togglePause() }
                    .disabled(recorder.isTransitioning)
                Button("停止录屏并保存") { recorder.stop() }.disabled(recorder.isTransitioning)
            } else if recorder.phase == .selecting || recorder.phase == .countdown {
                Button("取消录屏") { recorder.cancelPreparation() }
            } else if recorder.phase == .saving {
                Text("正在保存录屏…")
            }
            Divider()
            Button("预览解锁问候") {
                appDelegate.showGreetingPreview()
            }
            Divider()
            Button("显示 / 隐藏灵动岛") {
                WindowManager.toggleVisible()
            }
            Divider()
            Button("退出灵动岛") {
                NSApp.terminate(nil)
            }
        }
    }
}
