import Foundation
import Darwin

/// Blocking helper for worker queues. Drain stdout while the process runs so
/// output larger than the pipe buffer cannot deadlock the caller.
nonisolated enum ProcessRunner {
    static func readStandardOutput(
        of process: Process,
        timeout: TimeInterval,
        requiresSuccessfulExit: Bool = true
    ) -> Data? {
        let output = Pipe()
        defer {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        do { try process.run() } catch { return nil }
        try? output.fileHandleForWriting.close()

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let executionDeadline = DispatchTime.now() + timeout
        var drainDeadline: DispatchTime?
        var reachedEnd = false
        var completed = false
        while true {
            let running = process.isRunning
            if reachedEnd && !running { completed = true; break }
            let now = DispatchTime.now()
            if running {
                if now >= executionDeadline { break }
            } else {
                // A descendant can keep stdout open after the direct child exits.
                if drainDeadline == nil { drainDeadline = now + 1 }
                if let drainDeadline, now >= drainDeadline { break }
            }
            if reachedEnd {
                _ = terminated.wait(timeout: .now() + .milliseconds(20))
                continue
            }
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&event, 1, 20)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            guard ready > 0 else { continue }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                result.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                reachedEnd = true
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                break
            }
        }

        if process.isRunning {
            process.terminate()
            if terminated.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 1)
            }
        }
        // All reads stay on this worker; returning closes the pipe even if a
        // descendant is still alive. No blocked background read survives a timeout.
        guard completed, !process.isRunning,
              !requiresSuccessfulExit || process.terminationStatus == 0 else { return nil }
        return result
    }
}
