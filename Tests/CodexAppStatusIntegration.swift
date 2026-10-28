import Foundation

@main
struct CodexAppStatusIntegration {
    static func main() throws {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            assertions += 1
        }
        let started = 1_792_932_561_000.0
        let projection = CodexAppThreadProjection(host: "durable", thread: "remote-thread")
        let turn: [String: Any] = ["turnId": "remote-turn", "status": "inProgress", "turnStartedAtMs": started]
        let state: [String: Any] = [
            "id": "remote-thread", "title": "实现前台流程编辑同步", "cwd": "/projects/RuYi",
            "updatedAt": started + 10_000, "threadRuntimeStatus": ["type": "active"], "turns": [],
            "turnHistory": ["kind": "canonical", "history": ["entitiesByKey": ["turn:remote-turn": turn]]]
        ]
        check(projection.apply(["type": "snapshot", "revision": 4, "conversationState": state]), "Canonical cloud snapshot loads")
        check(projection.snapshot()?.title == "实现前台流程编辑同步", "Screenshot task title survives")
        check(projection.snapshot()?.state == .working, "Cloud task is detected without any local rollout or writer lock")
        check(projection.snapshot()?.projectName == "RuYi", "Remote cwd supplies the project name")
        check(projection.snapshot()?.id == "app:durable:remote-turn", "Remote turn ID is namespaced")
        check(projection.snapshot()?.startedAt.timeIntervalSince1970 == started / 1000, "Elapsed clock uses milliseconds correctly")
        func patches(_ base: Int, _ next: Int, _ values: [[String: Any]]) -> [String: Any] {
            ["type": "patches", "baseRevision": base, "revision": next, "patches": values]
        }
        let prefix = ["turnHistory", "history", "entitiesByKey", "turn:remote-turn"]
        check(projection.apply(patches(4, 5, [
            ["op": "add", "path": prefix + ["items", "0"], "value": ["text": "tool output"]],
            ["op": "replace", "path": ["turnHistory", "history", "islands"], "value": []]
        ])), "Content and pagination updates do not lose the status or require another snapshot")
        check(projection.snapshot()?.state == .working, "Streaming content retains the active turn")
        check(projection.apply(patches(5, 6, [
            ["op": "replace", "path": prefix + ["status"], "value": "completed"],
            ["op": "replace", "path": prefix + ["durationMs"], "value": 25_000]
        ])), "Completion patches apply")
        check(projection.snapshot()?.state == .completed, "Completed task stops reporting work")
        check(projection.snapshot()?.updatedAt.timeIntervalSince1970 == (started + 25_000) / 1000, "Completed elapsed time freezes")
        check(!projection.apply(patches(3, 7, [])), "A missing revision requests a fresh snapshot")
        check(!projection.apply(["type": "snapshot", "revision": 8, "conversationState": ["id": "wrong-thread"]]), "Cross-thread state is rejected")

        let legacy = CodexAppThreadProjection(host: "remote", thread: "legacy")
        check(legacy.apply(["type": "snapshot", "revision": 1, "conversationState": ["id": "legacy", "turns": [turn]]]), "Legacy remote histories are supported")
        check(legacy.apply(patches(1, 2, [["op": "replace", "path": ["turns", 0, "status"], "value": "interrupted"]])), "Numeric legacy patch paths apply")
        check(legacy.snapshot()?.state == .interrupted, "Interruptions remain distinct from successful completion")
        var mixed = state
        mixed["turns"] = [turn]
        let mixedProjection = CodexAppThreadProjection(host: "durable", thread: "remote-thread")
        check(mixedProjection.apply(["type": "snapshot", "revision": 4, "conversationState": mixed]), "A transitional snapshot can contain both history formats")
        check(mixedProjection.apply(patches(4, 5, [["op": "replace", "path": prefix + ["status"], "value": "failed"]])), "Failure patch applies to canonical history")
        check(mixedProjection.snapshot()?.state == .failed, "A stale legacy copy cannot keep a failed canonical turn working")
        check(!mixedProjection.apply(patches(5, 6, [["op": "replace", "path": ["turnHistory"], "value": [:]]])), "A history reset requests a fresh snapshot")
        let empty = CodexAppStatusReader(socketPath: "/tmp/dynamic-island-missing-\(UUID().uuidString).sock")
        check(empty.readTasks().isEmpty, "Unavailable application does not produce phantom tasks")
        assertions += try CodexRecoveryIntegration.run()
        print("PASS: \(assertions) cloud snapshot, streaming, completion, interruption and recovery assertions")

        if CommandLine.arguments.contains("--live") {
            let reader = CodexAppStatusReader()
            var snapshots: [CodexTaskSnapshot] = []
            for _ in 0..<40 {
                snapshots = reader.readTasks()
                if !snapshots.isEmpty { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard !snapshots.isEmpty else { fatalError("No remote tasks received from the running app") }
            for snapshot in snapshots { print("LIVE: \(snapshot.title) | \(snapshot.state.rawValue) | \(snapshot.projectName)") }
        }
    }
}
