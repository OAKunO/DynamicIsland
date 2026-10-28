import AppKit

/// Notifications can precede the WindowServer's session update or be missed during login.
/// Always reconcile against the current session, with periodic checks as a fallback.
final class IslandSessionMonitor: NSObject {
    private let workspaceCenter: NotificationCenter
    private let distributedCenter: NotificationCenter
    private let readSession: () -> Bool?
    private let onLock: () -> Void
    private let onUnlock: (_ showsGreeting: Bool) -> Void
    private var timer: Timer?
    private var isMonitoring = false
    private var lastUnlockedState: Bool?

    init(
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        distributedCenter: NotificationCenter = DistributedNotificationCenter.default(),
        readSession: @escaping () -> Bool? = IslandSessionMonitor.currentSessionIsUnlocked,
        onLock: @escaping () -> Void,
        onUnlock: @escaping (Bool) -> Void
    ) {
        self.workspaceCenter = workspaceCenter
        self.distributedCenter = distributedCenter
        self.readSession = readSession
        self.onLock = onLock
        self.onUnlock = onUnlock
    }

    func start(periodicChecks: Bool = true) {
        guard !isMonitoring else { return }
        isMonitoring = true
        lastUnlockedState = nil
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            workspaceCenter.addObserver(self, selector: #selector(handleLock(_:)), name: name, object: nil)
        }
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification] {
            workspaceCenter.addObserver(self, selector: #selector(handleSessionChange(_:)), name: name, object: nil)
        }
        distributedCenter.addObserver(self, selector: #selector(handleLock(_:)),
            name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        distributedCenter.addObserver(self, selector: #selector(handleSessionChange(_:)),
            name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)

        // Register first so login/unlock cannot happen between the first read and subscription.
        reconcile()
        guard periodicChecks else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.reconcile()
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        isMonitoring = false
        timer?.invalidate()
        timer = nil
        workspaceCenter.removeObserver(self)
        distributedCenter.removeObserver(self)
    }

    func reconcile() {
        guard isMonitoring else { return }
        guard let unlocked = readSession() else {
            // An unavailable session is not proof of an authenticated unlock.
            publish(unlocked: false)
            return
        }
        publish(unlocked: unlocked)
    }

    private func publish(unlocked: Bool) {
        guard unlocked != lastUnlockedState else { return }
        let isInitialRead = lastUnlockedState == nil
        lastUnlockedState = unlocked
        if unlocked { onUnlock(!isInitialRead) }
        else { onLock() }
    }

    @objc private func handleSessionChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.reconcile() }
    }

    @objc private func handleLock(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, isMonitoring else { return }
            publish(unlocked: false)
        }
    }

    private nonisolated static func currentSessionIsUnlocked() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool else { return nil }
        return onConsole && (session["CGSSessionScreenIsLocked"] as? Bool) != true
    }
}
