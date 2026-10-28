import AppKit

@main
struct SessionRecoveryIntegration {
    @MainActor static func main() {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            assertions += 1
        }
        func deliverNotifications() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        let workspace = NotificationCenter()
        let distributed = NotificationCenter()
        var session: Bool? = false
        var isUnlocked = true
        var locks = 0
        var unlockGreetings: [Bool] = []
        let monitor = IslandSessionMonitor(
            workspaceCenter: workspace, distributedCenter: distributed,
            readSession: { session },
            onLock: { isUnlocked = false; locks += 1 },
            onUnlock: { isUnlocked = true; unlockGreetings.append($0) }
        )
        monitor.start(periodicChecks: false)
        check(!isUnlocked && locks == 1, "Launching while locked immediately masks content")

        // Reproduce the bug: notification arrives before the session dictionary updates.
        distributed.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        deliverNotifications()
        check(!isUnlocked, "Early unlock notification must not bypass authentication")
        session = true
        monitor.reconcile()
        check(isUnlocked && unlockGreetings == [true], "A later check recovers the ignored early unlock")
        for _ in 0..<10 { monitor.reconcile() }
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        distributed.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        deliverNotifications()
        check(unlockGreetings == [true], "Polling and duplicate notifications do not repeat greetings")

        // Neither notification arrives: the current session still drives recovery.
        session = false
        monitor.reconcile()
        check(!isUnlocked, "A missed lock event still masks private content")
        session = true
        monitor.reconcile()
        check(isUnlocked && unlockGreetings.count == 2, "A missed unlock event cannot leave the island locked")

        session = nil
        monitor.reconcile()
        check(!isUnlocked, "An unavailable session fails closed")
        session = true
        monitor.reconcile()
        check(isUnlocked, "A transiently unavailable dictionary cannot permanently lock the island")

        session = false
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        deliverNotifications()
        check(!isUnlocked, "Sleep masks private content")
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        deliverNotifications()
        check(!isUnlocked, "Wake alone does not prove the user unlocked")
        session = true
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        deliverNotifications()
        check(isUnlocked, "Screen wake reconciles the authenticated session")
        monitor.stop()
        let locksBeforeStop = locks
        distributed.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        session = false
        monitor.reconcile()
        deliverNotifications()
        check(isUnlocked && locks == locksBeforeStop, "Stopped monitoring cannot mutate state")

        var startupGreetings: [Bool] = []
        session = true
        let startup = IslandSessionMonitor(readSession: { session }, onLock: {},
            onUnlock: { startupGreetings.append($0) })
        startup.start(periodicChecks: false)
        check(startupGreetings == [false], "A normal app launch restores interaction without an unlock greeting")
        startup.stop()

        // Exercise the actual fallback timer, without sending an unlock notification.
        session = nil
        var recovered = false
        let fallback = IslandSessionMonitor(readSession: { session }, onLock: { recovered = false },
            onUnlock: { _ in recovered = true })
        fallback.start()
        fallback.start() // Starting twice must not install a second observer/timer.
        check(!recovered, "Unknown startup state stays private")
        session = true
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        check(recovered, "The scheduled fallback recovers login without any notification")
        fallback.stop()
        print("PASS: \(assertions) startup, early/missing notifications, wake, privacy and timer recovery assertions")
    }
}
