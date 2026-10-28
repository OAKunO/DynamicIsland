import Foundation
import Darwin

@main
struct ProcessRunnerIntegration {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            checks += 1
        }
        func process(_ arguments: [String]) -> Process {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = arguments
            return child
        }

        // Child fixtures use this executable, without a shell or external tools.
        switch CommandLine.arguments.dropFirst().first {
        case "--empty-output":
            return
        case "--echo":
            FileHandle.standardOutput.write(Data(CommandLine.arguments[2].utf8))
            return
        case "--close-output":
            Darwin.close(STDOUT_FILENO)
            Thread.sleep(forTimeInterval: 30)
            return
        case "--large-output":
            FileHandle.standardOutput.write(Data(repeating: 65, count: 256 * 1024))
            return
        case "--failed":
            FileHandle.standardOutput.write(Data("partial output".utf8))
            exit(7)
        case "--ignore-termination":
            signal(SIGTERM, SIG_IGN)
            FileHandle.standardOutput.write(Data("ready".utf8))
            Thread.sleep(forTimeInterval: 30)
            return
        case "--inherit-output":
            let child = process(["--delayed-output", CommandLine.arguments[2]])
            child.standardOutput = FileHandle.standardOutput
            child.standardError = FileHandle.nullDevice
            try child.run()
            return
        case "--delayed-output":
            signal(SIGPIPE, SIG_IGN)
            Thread.sleep(forTimeInterval: 2)
            let count = Data("late output".utf8).withUnsafeBytes {
                Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count)
            }
            try Data((count < 0 && errno == EPIPE ? "closed" : "open").utf8)
                .write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
            return
        default: break
        }

        let large = ProcessRunner.readStandardOutput(of: process(["--large-output"]), timeout: 5)
        check(large == Data(repeating: 65, count: 256 * 1024),
              "Output exceeding the pipe buffer is drained completely without deadlock")
        check(ProcessRunner.readStandardOutput(of: process(["--empty-output"]), timeout: 5) == Data(),
              "A successful command with no output still completes")
        check(ProcessRunner.readStandardOutput(of: process(["--failed"]), timeout: 5) == nil,
              "Failed commands do not supply a successful result")
        let partial = ProcessRunner.readStandardOutput(of: process(["--failed"]), timeout: 5,
                                                     requiresSuccessfulExit: false)
        check(partial == Data("partial output".utf8), "lsof-style callers can retain output from a nonzero exit")
        let missing = Process()
        missing.executableURL = URL(fileURLWithPath: "/nonexistent/DynamicIsland-test-command")
        check(ProcessRunner.readStandardOutput(of: missing, timeout: 1) == nil,
              "Launch failure returns no output")

        let stalled = process(["--ignore-termination"])
        let start = ProcessInfo.processInfo.systemUptime
        check(ProcessRunner.readStandardOutput(of: stalled, timeout: 0.5) == nil,
              "A timed-out command cannot publish incomplete output")
        check(!stalled.isRunning, "A command ignoring SIGTERM is stopped")
        check(ProcessInfo.processInfo.systemUptime - start < 5, "Timeout cleanup has a bounded wait")
        let closed = process(["--close-output"])
        check(ProcessRunner.readStandardOutput(of: closed, timeout: 0.2) == nil && !closed.isRunning,
              "Closing stdout cannot bypass the command timeout or leave the process running")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProcessRunner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("inherited-output-result")
        let inherited = process(["--inherit-output", marker.path])
        check(ProcessRunner.readStandardOutput(of: inherited, timeout: 5) == nil,
              "An inherited pipe has a bounded drain wait after its parent exits")
        let markerDeadline = ProcessInfo.processInfo.systemUptime + 4
        while !FileManager.default.fileExists(atPath: marker.path),
              ProcessInfo.processInfo.systemUptime < markerDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        check((try? String(contentsOf: marker, encoding: .utf8)) == "closed",
              "Returning from a pipe timeout must release the reader, not leave a blocked worker behind")
        DispatchQueue.concurrentPerform(iterations: 4) { index in
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--echo", "result-\(index)"]
            precondition(ProcessRunner.readStandardOutput(of: child, timeout: 5) == Data("result-\(index)".utf8),
                         "Concurrent callers must receive only their own process output")
        }
        checks += 4
        print("PASS: \(checks) process output, launch failure, nonzero exit and timeout checks")
    }
}
