import Foundation

@main
struct IslandDisplaySettingsIntegration {
    @MainActor static func main() {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            assertions += 1
        }
        let suite = "DynamicIsland.DisplaySettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IslandDisplaySettings(defaults: defaults)
        let features = IslandDisplayFeature.allCases
        check(settings.enabledCount == features.count && features.allSatisfy(settings.snapshot.isEnabled),
              "All existing features stay visible before the user changes a setting")
        for feature in features {
            settings.setEnabled(false, for: feature)
            check(!settings.snapshot.isEnabled(feature), "Each feature has an independent switch")
            let restored = IslandDisplaySettings(defaults: defaults)
            check(!restored.snapshot.isEnabled(feature), "Hidden features survive reopening and relaunch")
        }
        check(settings.enabledCount == 0, "All display features may be hidden")
        settings.enableAllDisplayFeatures()
        check(settings.enabledDisplayCount == IslandDisplayFeature.displayFeatures.count,
              "Display-page enable all restores its own content")
        check(settings.enabledFunctionCount == 0 && !settings.snapshot.isEnabled(.unlockGreeting),
              "Display-page enable all preserves a disabled unlock greeting")
        let restoredFunctions = IslandDisplaySettings(defaults: defaults)
        check(restoredFunctions.enabledDisplayCount == IslandDisplayFeature.displayFeatures.count && !restoredFunctions.snapshot.isEnabled(.unlockGreeting),
              "The existing greeting preference persists when moved to the functions page")
        settings.enableAll()
        check(IslandDisplaySettings(defaults: defaults).snapshot.hiddenFeatures.isEmpty,
              "Enable all restores and saves every feature")

        var running = IslandLengthConfiguration(
            agents: IslandAgentProvider.allCases.map { .init(provider: $0, statuses: [.working]) },
            music: true, timer: .runningHours, battery: .lowCharging, usb: true,
            expandedTaskCount: 3, pomodoro: .pausedMinutes, enabledAlarmCount: 4
        )
        let original = running
        for mask in 0..<(1 << features.count) {
            let hidden = Set(features.enumerated().compactMap { mask & (1 << $0.offset) == 0 ? nil : $0.element })
            let visibility = IslandDisplaySettingsSnapshot(hiddenFeatures: hidden)
            let displayed = visibility.filtering(running)
            check(displayed.agents.allSatisfy { visibility.isProviderEnabled($0.provider) },
                  "Hidden providers cannot affect AI layout")
            check(displayed.agents.count == running.agents.filter { visibility.isProviderEnabled($0.provider) }.count,
                  "Visible AI providers must not disappear")
            check(displayed.compactActivities == running.compactActivities.filter(visibility.isActivityEnabled),
                  "Parity counts only selected display features")
            check(displayed.music == visibility.isEnabled(.music) && displayed.usb == visibility.isEnabled(.usb),
                  "Music and USB visibility apply independently")
            check(displayed.compactAlarmCount == (visibility.isEnabled(.alarm) ? 4 : 0),
                  "Alarm counts are removed from geometry when hidden")
            check(running == original, "Changing presentation must not alter source activity state")
        }
        let allHidden = IslandDisplaySettingsSnapshot(hiddenFeatures: Set(features))
        let idle = allHidden.filtering(running)
        check(idle.compactActivities.isEmpty && idle.agents.isEmpty && WindowManager.defaultSize(for: idle).width == WindowManager.notchGeometry.idleWidth,
              "All hidden content restores the idle island width")
        var expanded = original
        expanded.mode = .expandedTimerSetup
        let recordingHidden = IslandDisplaySettingsSnapshot(hiddenFeatures: [.recording]).filtering(expanded)
        check(recordingHidden.showsTimeTools && !recordingHidden.showsRecordingTools,
              "Hiding recording retains the independent time area")
        let timeHidden = IslandDisplaySettingsSnapshot(hiddenFeatures: [.timer, .pomodoro, .alarm]).filtering(expanded)
        check(!timeHidden.showsTimeTools && timeHidden.showsRecordingTools,
              "Hiding the three time tools retains the independent recording area")
        check(WindowManager.defaultSize(for: timeHidden).width == 702 + WindowManager.recordingColumnWidth,
              "The recording area has its own width beside AI and music")
        let emptyExpanded = IslandLengthConfiguration(mode: .expandedTimerSetup)
        let onlyRecording = IslandDisplaySettingsSnapshot(hiddenFeatures: [.timer, .pomodoro, .alarm]).filtering(emptyExpanded)
        let onlyTime = IslandDisplaySettingsSnapshot(hiddenFeatures: [.recording]).filtering(emptyExpanded)
        check(WindowManager.defaultSize(for: onlyRecording).width == max(WindowManager.recordingColumnWidth, WindowManager.notchGeometry.minimumExpandedWidth) && WindowManager.defaultSize(for: onlyTime).width == 344,
              "Either area can be shown independently at its own compact width")
        check(onlyRecording.key != onlyTime.key && onlyTime.key != emptyExpanded.key,
              "Single-area layouts retain separate saved width preferences")
        let noTimeTools = IslandDisplaySettingsSnapshot(hiddenFeatures: [.timer, .pomodoro, .alarm, .recording])
        let withoutTimeColumn = noTimeTools.filtering(expanded)
        check(WindowManager.defaultSize(for: withoutTimeColumn).width == 701,
              "Hidden time tools remove the expanded time column while AI and music stay visible")
        check(withoutTimeColumn.key != expanded.key,
              "The expanded layout without time tools uses a separate length preference")
        check(WindowManager.defaultSize(for: allHidden.filtering(expanded)).width == 344,
              "All hidden features retain a small expanded settings entry")
        var phoneExpanded = emptyExpanded
        phoneExpanded.usb = true
        phoneExpanded.phone = true
        let phoneHidden = IslandDisplaySettingsSnapshot(hiddenFeatures: [.usb]).filtering(phoneExpanded)
        check(!phoneHidden.phone && !phoneHidden.usb && phoneHidden.key == emptyExpanded.key,
              "The USB switch hides phone details and removes their width together")
        let phoneOnly = noTimeTools.filtering(phoneExpanded)
        check(phoneOnly.phone && WindowManager.defaultSize(for: phoneOnly).width == max(180, WindowManager.notchGeometry.minimumExpandedWidth),
              "Disabling other tools retains only the narrow phone area")
        let exclusiveRecording = IslandDisplaySettingsSnapshot().forRecording(isActive: true, showsStatus: true, coexists: false)
        check(!exclusiveRecording.filtering(phoneExpanded).phone,
              "Exclusive recording must hide the connected phone area")
        var computerExpanded = phoneExpanded
        computerExpanded.computer = true
        let computerHidden = IslandDisplaySettingsSnapshot(hiddenFeatures: [.computer]).filtering(computerExpanded)
        check(!computerHidden.computer && computerHidden.phone && computerHidden.key == phoneExpanded.key,
              "Hiding the computer removes its column and width preference independently of USB")
        check(IslandDisplaySettingsSnapshot(hiddenFeatures: [.battery, .usb]).filtering(computerExpanded).computer,
              "The computer overview stays available when compact battery and USB indicators are hidden")
        check(!exclusiveRecording.filtering(computerExpanded).computer,
              "Exclusive recording hides computer details too")
        let computerOnly = IslandDisplaySettingsSnapshot(hiddenFeatures: [.timer, .pomodoro, .alarm, .recording, .usb]).filtering(computerExpanded)
        check(WindowManager.defaultSize(for: computerOnly).width == max(180, WindowManager.notchGeometry.minimumExpandedWidth),
              "A computer-only dashboard reserves no empty tool columns")
        let onlyTimer = IslandDisplaySettingsSnapshot(hiddenFeatures: Set(features.filter { $0 != .timer }))
        let timer = onlyTimer.filtering(running)
        let plan = CompactActivityLayout(visible: timer.compactActivities)
        check(plan.dual == .timer && plan.activities(on: .left) == [.timer] && plan.activities(on: .right) == [.timer],
              "Hiding other features restores a single timer's dual-side display")
        running.timer = .alarm
        running.enabledAlarmCount = 0
        check(!onlyTimer.filtering(running).compactActivities.contains(.alarm),
              "The legacy alarm activity is hidden by the alarm switch, independently of timer")
        settings.setEnabled(false, for: .timer)
        let model = IslandModel(playsAlertSound: false, timeToolDefaults: defaults)
        model.isRecordingSettingsPresented = true
        model.selectedTimeTool = .pomodoro
        check(model.isRecordingSettingsPresented,
              "Switching time tabs leaves the independent recording sidebar open")
        model.setTimer(totalSeconds: 120)
        model.startTimer()
        model.startPomodoro()
        _ = settings.snapshot.filtering(original)
        check(model.isTimerRunning && model.pomodoro.isRunning && model.timeRemaining == 120,
              "Display changes leave active countdowns running")
        model.cancelTimer()
        model.resetPomodoro()
        print("PASS: \(assertions) display visibility, persistence and filtering checks")
    }
}
