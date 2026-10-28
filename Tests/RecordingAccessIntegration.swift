import AppKit
import ScreenCaptureKit

@main
struct RecordingAccessIntegration {
    @MainActor static func main() async throws {
        let suite = "DynamicIsland.RecordingAccessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = RecordingSettings(defaults: defaults)
        settings.configuration.microphone = false
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }
            checks += 1
        }

        // Reaching this provider must not depend on a separate CoreGraphics
        // permission check, or prompt for actual screen access during the test.
        var requests = 0
        let probe = NSError(domain: "RecordingAccessTest", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Reached capture framework"])
        let controller = ScreenRecordingController(settings: settings) {
            requests += 1
            if requests == 1 {
                throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
            }
            throw probe
        }
        controller.start()
        try await settle(controller)
        check(requests == 1, "The capture framework must decide whether screen access is permitted")
        check(controller.errorMessage?.contains("重新打开") == true,
              "Permission denial explains what to do when the settings switch is already enabled")
        check(!controller.isBusy, "Permission denial returns to idle so recording can be retried")

        controller.start()
        check(controller.errorMessage == nil, "Retry clears the previous permission error")
        try await settle(controller)
        check(requests == 2, "Retry must recheck actual access instead of caching a denial")
        check(controller.errorMessage == probe.localizedDescription,
              "A later framework error must not be mislabeled as missing screen permission")

        let cancelled = ScreenRecordingController(settings: settings) { throw CancellationError() }
        cancelled.start()
        try await settle(cancelled)
        check(cancelled.errorMessage == nil && !cancelled.isBusy,
              "Cancelling access preparation returns to idle without a permission warning")

        let otherError = NSError(domain: "OtherFramework", code: SCStreamError.Code.userDeclined.rawValue,
                                 userInfo: [NSLocalizedDescriptionKey: "Unrelated failure"])
        let unrelated = ScreenRecordingController(settings: settings) { throw otherError }
        unrelated.start()
        try await settle(unrelated)
        check(unrelated.errorMessage == otherError.localizedDescription,
              "Only ScreenCaptureKit authorization failures receive screen permission guidance")
        print("PASS: \(checks) recording access, retry, cancellation and error classification checks")
    }

    @MainActor private static func settle(_ controller: ScreenRecordingController) async throws {
        let deadline = Date().addingTimeInterval(2)
        while controller.isBusy && Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard !controller.isBusy else { fatalError("Recording preparation did not finish") }
    }
}
