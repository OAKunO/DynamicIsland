import Foundation

@main
struct TimeToolsIntegration {
    @MainActor static func main() async throws {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            assertions += 1
        }
        let now = Date()
        let suite = "DynamicIsland.TimeToolsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var session = PomodoroSession()
        session.start(at: now)
        session.refresh(at: now.addingTimeInterval(65))
        check(session.remaining == 1435, "Focus uses its deadline rather than tick counts")
        session.togglePause(at: now.addingTimeInterval(65))
        session.refresh(at: now.addingTimeInterval(1000))
        check(session.remaining == 1435 && session.isPaused, "Paused focus must not advance")
        session.togglePause(at: now.addingTimeInterval(1000))
        check(session.refresh(at: now.addingTimeInterval(2435)) == .focus, "Resume preserves remaining focus time")
        check(session.phase == .shortBreak && session.completedFocusCount == 1 && !session.isRunning,
              "A focus completion prepares a break without silently starting it")
        check(session.refresh(at: now.addingTimeInterval(90000)) == nil,
              "Sleep must not create phantom focus sessions")
        var cursor = now.addingTimeInterval(90000)
        for round in 1...4 {
            if round > 1 {
                session.start(at: cursor)
                cursor.addTimeInterval(1500)
                session.refresh(at: cursor)
                check(session.completedFocusCount == round, "Each focus records exactly one completed round")
            }
            check(session.phase == (round == 4 ? .longBreak : .shortBreak), "Fourth focus gets a long break")
            session.start(at: cursor)
            cursor.addTimeInterval(TimeInterval(session.phaseDuration))
            session.refresh(at: cursor)
            check(session.phase == .focus && session.remaining == 1500, "Break returns to focus")
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let reference = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 23, minute: 30))!
        let time = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 8, minute: 0))!
        check(AlarmSchedule.deadline(for: time, after: reference, calendar: calendar) == nil,
              "Explicit dates in the past must not silently schedule tomorrow")
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: time)!
        let alarm = AlarmSchedule.deadline(for: tomorrow, after: reference, calendar: calendar)!
        check(calendar.component(.day, from: alarm) == 6 && calendar.component(.hour, from: alarm) == 8,
              "An explicit future date must be preserved")
        let earlier = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 7))!
        check(calendar.component(.day, from: AlarmSchedule.deadline(for: time, after: earlier, calendar: calendar)!) == 5,
              "A future clock time schedules today")
        check(AlarmSchedule.deadline(for: time, after: time, calendar: calendar) == nil,
              "The current minute must not create an immediately overdue alarm")
        check(AlarmSchedule.deadline(for: time.addingTimeInterval(45), after: earlier, calendar: calendar) == time,
              "An alarm targets the displayed minute, not invisible seconds")
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let spring = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0))!
        let missingTime = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 2, minute: 30))!
        check(AlarmSchedule.deadline(for: missingTime, after: spring, calendar: calendar) == nil,
              "Explicit dates remain past even across a DST boundary")

        let model = IslandModel(playsAlertSound: false, timeToolDefaults: defaults)
        model.setTimer(totalSeconds: 60)
        model.startTimer()
        model.startPomodoro(at: now)
        model.alarmTime = now.addingTimeInterval(3600)
        model.scheduleAlarm(at: now)
        let deadline = model.alarmDeadline!
        model.selectedTimeTool = .pomodoro
        check(model.isTimerRunning && model.pomodoro.isRunning && model.alarmDeadline != nil,
              "Switching tools preserves all three active clocks")
        check(model.compactTool == .pomodoro, "Compact view follows an active selected tool")
        check(model.compactText(for: .timer) == "01:00" && model.compactText(for: .pomodoro) == "25:00",
              "Concurrent countdowns retain independent display values")
        var compactPreview = IslandLengthConfiguration(timer: .runningHours)
        compactPreview.pomodoro = .pausedHours
        compactPreview.enabledAlarmCount = 3
        let preview = IslandModel(previewConfiguration: compactPreview, playsAlertSound: false, timeToolDefaults: defaults)
        check(preview.isTimerRunning && preview.pomodoro.isRunning && preview.enabledAlarmCount == 3,
              "Width previews display every concurrent clock and the actual enabled alarm count")
        check(preview.isPaused(.pomodoro) && preview.compactText(for: .pomodoro) == "01:02:00",
              "Hour-length pomodoro previews preserve both their duration and pause appearance")
        model.togglePause()
        check(model.isPaused(.timer) && !model.isPaused(.pomodoro),
              "Each compact tool uses its own paused state")
        model.refreshTimeTools(at: now.addingTimeInterval(65))
        check(model.isTimerPaused && model.timeRemaining > 0 && model.pomodoro.remaining == 1435,
              "Pausing the timer does not pause the pomodoro")
        model.cancelTimer()
        check(model.alarmDeadline == deadline && model.pomodoro.isRunning,
              "Canceling one clock leaves the others intact")
        model.refreshTimeTools(at: deadline.addingTimeInterval(1))
        check(model.completionTitle == "专注完成" && model.isTimerFinished,
              "Multiple due clocks queue their alerts")
        check(!model.pomodoro.isRunning && model.alarmDeadline == nil,
              "An overdue alarm fires once after sleep")
        model.dismissTimerFinishedAlert()
        check(model.completionTitle == "闹钟响了" && model.isTimerFinished,
              "Acknowledging one completion reveals the queued alarm")
        model.dismissTimerFinishedAlert()
        check(!model.isTimerFinished, "Acknowledging all alerts clears the persistent presentation")
        model.refreshTimeTools(at: deadline.addingTimeInterval(100))
        check(!model.isTimerFinished, "A fired one-time alarm must not ring again")
        model.startPomodoro(at: now)
        model.resetPomodoro()
        check(model.pomodoro == PomodoroSession(), "Reset clears the phase, count and deadline")

        var configuration = PomodoroConfiguration()
        configuration.focusMinutes = 40
        configuration.shortBreakMinutes = 7
        configuration.longBreakMinutes = 22
        configuration.longBreakInterval = 2
        configuration.rounds = 3
        configuration.isUnlimited = false
        configuration.autoAdvance = true
        var custom = PomodoroSession(configuration: configuration)
        custom.start(at: now)
        check(custom.remaining == 2400, "Custom focus duration starts correctly")
        var customCursor = now.addingTimeInterval(2400)
        custom.refresh(at: customCursor)
        check(custom.phase == .shortBreak && custom.remaining == 420 && custom.isRunning,
              "Automatic cycling uses the custom short break")
        customCursor.addTimeInterval(420)
        custom.refresh(at: customCursor)
        check(custom.phase == .focus && custom.remaining == 2400 && custom.isRunning,
              "Automatic cycling returns to the custom focus")
        customCursor.addTimeInterval(2400)
        custom.refresh(at: customCursor)
        check(custom.phase == .longBreak && custom.remaining == 1320,
              "Custom long-break frequency and duration apply")
        customCursor.addTimeInterval(1320)
        custom.refresh(at: customCursor)
        customCursor.addTimeInterval(2400)
        custom.refresh(at: customCursor)
        check(custom.isComplete && custom.completedFocusCount == 3 && !custom.isRunning && custom.deadline == nil,
              "A finite group stops after the requested number of focus rounds")
        custom.start(at: customCursor)
        check(!custom.isRunning, "A completed group must be reset before restarting")

        configuration.isUnlimited = true
        var unlimited = PomodoroSession(configuration: configuration)
        unlimited.start(at: now)
        var unlimitedCursor = now
        for _ in 0..<12 {
            unlimitedCursor.addTimeInterval(TimeInterval(unlimited.phaseDuration))
            unlimited.refresh(at: unlimitedCursor)
        }
        check(unlimited.completedFocusCount == 6 && unlimited.isRunning && !unlimited.isComplete,
              "Unlimited mode keeps cycling beyond the stored finite round count")
        unlimited.refresh(at: unlimitedCursor.addingTimeInterval(90000))
        check(unlimited.completedFocusCount == 7 && unlimited.remaining == configuration.shortBreakMinutes * 60,
              "Automatic cycling after sleep advances one phase without phantom sessions")
        unlimited.togglePause(at: unlimitedCursor.addingTimeInterval(90010))
        let pausedRemaining = unlimited.remaining
        unlimited.refresh(at: unlimitedCursor.addingTimeInterval(99999))
        check(unlimited.isPaused && unlimited.remaining == pausedRemaining, "Custom cycles respect pause")

        model.resetPomodoro()
        model.updatePomodoroConfiguration(configuration)
        check(model.pomodoro.remaining == 2400, "Editing idle settings updates the preview duration")
        let restored = IslandModel(playsAlertSound: false, timeToolDefaults: defaults)
        check(restored.pomodoroConfiguration == configuration && restored.pomodoro.remaining == 2400,
              "Customized settings survive relaunch")
        model.startPomodoro(at: now)
        var changed = configuration
        changed.focusMinutes = 1
        model.updatePomodoroConfiguration(changed)
        check(model.pomodoroConfiguration == configuration, "Settings must not silently reset an active focus")
        model.resetPomodoro()
        check(model.pomodoro.remaining == 2400 && model.pomodoro.completedFocusCount == 0,
              "Reset preserves chosen durations and clears progress")
        changed.focusMinutes = -3
        changed.shortBreakMinutes = 500
        changed.longBreakInterval = 0
        changed.rounds = 1000
        model.updatePomodoroConfiguration(changed)
        check(model.pomodoroConfiguration.focusMinutes == 1 && model.pomodoroConfiguration.shortBreakMinutes == 60 &&
              model.pomodoroConfiguration.longBreakInterval == 1 && model.pomodoroConfiguration.rounds == 99,
              "Typed settings clamp to valid positive bounds")
        for alarm in model.alarms { model.deleteAlarm(alarm.id) }
        model.alarmTime = now.addingTimeInterval(-300)
        model.scheduleAlarm(at: now)
        check(model.alarmDeadline == nil, "Past alarm dates are rejected by the model as well as the UI")

        let alarmSuite = "DynamicIsland.AlarmTests.\(UUID().uuidString)"
        let alarmDefaults = UserDefaults(suiteName: alarmSuite)!
        defer { alarmDefaults.removePersistentDomain(forName: alarmSuite) }
        let multiple = IslandModel(playsAlertSound: false, timeToolDefaults: alarmDefaults)
        multiple.selectedTimeTool = .alarm
        multiple.beginAddingAlarm(at: now)
        let defaultDate = multiple.alarmTime
        check(defaultDate.timeIntervalSince(now) > 3540 && defaultDate.timeIntervalSince(now) <= 3600,
              "Opening the add screen defaults to one hour ahead at minute precision")
        multiple.alarmTime = now.addingTimeInterval(7200)
        multiple.dismissAlarmEditor()
        multiple.beginAddingAlarm(at: now.addingTimeInterval(600))
        check(multiple.alarmTime == AlarmSchedule.defaultTime(after: now.addingTimeInterval(600)),
              "Reopening the add screen resets stale or canceled input")
        multiple.alarmTime = defaultDate
        multiple.scheduleAlarm(at: now)
        let first = multiple.alarms[0]
        check(!multiple.isAlarmEditorPresented && multiple.alarms.count == 1,
              "Saving returns to the alarm list")
        multiple.beginAddingAlarm(at: now)
        multiple.alarmTime = defaultDate.addingTimeInterval(600)
        multiple.scheduleAlarm(at: now)
        let second = multiple.alarms[1]
        check(multiple.alarms.count == 2 && multiple.alarms.allSatisfy(\.isEnabled),
              "Adding a second alarm keeps both enabled")
        check(multiple.enabledAlarmCount == 2 && multiple.compactText(for: .alarm) == "2",
              "Compact alarm labels count enabled alarms")
        check(multiple.hasActiveTimeTool && multiple.compactTool == .alarm &&
              !multiple.compactToolShowsCountdown && multiple.compactToolText.isEmpty,
              "Compact alarms show an icon without countdown text")
        multiple.setAlarmEnabled(first.id, false, at: now)
        check(multiple.enabledAlarmCount == 1 && multiple.compactText(for: .alarm) == "1",
              "Disabled saved alarms must not contribute to the displayed count")
        check(multiple.alarmDeadline == second.date && !multiple.alarms[0].isEnabled,
              "Disabling one alarm preserves the other deadline")
        let restoredAlarms = IslandModel(playsAlertSound: false, timeToolDefaults: alarmDefaults)
        check(restoredAlarms.alarms == multiple.alarms && restoredAlarms.alarmDeadline == second.date,
              "Alarm dates, identities and switches survive relaunch")
        multiple.beginEditingAlarm(second.id)
        multiple.alarmTime = defaultDate.addingTimeInterval(1200)
        multiple.dismissAlarmEditor()
        check(multiple.alarms[1] == second, "Canceling an edit leaves the scheduled alarm intact")
        multiple.beginEditingAlarm(second.id)
        multiple.alarmTime = defaultDate.addingTimeInterval(1200)
        multiple.scheduleAlarm(at: now)
        check(multiple.alarms.count == 2 && multiple.alarms[1].id == second.id &&
              multiple.alarms[1].date == defaultDate.addingTimeInterval(1200),
              "Editing replaces only the chosen alarm without duplicating it")
        multiple.setAlarmEnabled(first.id, true, at: now)
        multiple.refreshTimeTools(at: defaultDate)
        check(multiple.isTimerFinished && !multiple.alarms[0].isEnabled && multiple.alarms[1].isEnabled,
              "A due alarm disables itself and leaves later alarms running")
        multiple.dismissTimerFinishedAlert()
        multiple.refreshTimeTools(at: defaultDate.addingTimeInterval(1))
        check(!multiple.isTimerFinished, "An acknowledged alarm does not ring again")
        multiple.setAlarmEnabled(first.id, true, at: defaultDate.addingTimeInterval(1))
        let reenabled = multiple.alarms.first { $0.id == first.id }!
        check(reenabled.isEnabled && reenabled.date > defaultDate &&
              Calendar.current.component(.hour, from: reenabled.date) == Calendar.current.component(.hour, from: first.date) &&
              Calendar.current.component(.minute, from: reenabled.date) == Calendar.current.component(.minute, from: first.date),
              "Reenabling an elapsed alarm schedules the next matching clock time")
        multiple.deleteAlarm(first.id)
        check(multiple.alarms.count == 1 && multiple.alarms[0].id == second.id,
              "Deleting one alarm keeps the other alarm")
        multiple.beginAddingAlarm(at: now)
        multiple.alarmTime = multiple.alarms[0].date
        multiple.scheduleAlarm(at: now)
        let sharedDeadline = multiple.alarms[0].date
        multiple.refreshTimeTools(at: sharedDeadline)
        check(multiple.alarms.count == 2 && multiple.alarms.allSatisfy { !$0.isEnabled } && multiple.isTimerFinished,
              "Simultaneous alarms each fire and remain listed with their switches off")
        multiple.dismissTimerFinishedAlert()
        check(multiple.isTimerFinished && multiple.completionTitle == "闹钟响了",
              "Simultaneous alarms queue separate reminders")
        multiple.dismissTimerFinishedAlert()
        check(!multiple.isTimerFinished && !multiple.hasActiveTimeTool,
              "Acknowledging all simultaneous alarms clears active state")
        for alarm in multiple.alarms { multiple.deleteAlarm(alarm.id) }
        check(IslandModel(playsAlertSound: false, timeToolDefaults: alarmDefaults).alarms.isEmpty,
              "Deleted alarms stay deleted after relaunch")

        let legacyConfigurationData = Data(#"{"focusMinutes":32,"shortBreakMinutes":6,"longBreakMinutes":18,"longBreakInterval":3,"rounds":7,"isUnlimited":false,"autoAdvance":true}"#.utf8)
        defaults.set(legacyConfigurationData, forKey: "island.pomodoroConfiguration.v1")
        let migrated = IslandModel(playsAlertSound: false, timeToolDefaults: defaults)
        check(migrated.pomodoroConfiguration.focusMinutes == 32 &&
              migrated.pomodoroConfiguration.shortBreakMinutes == 6 &&
              migrated.pomodoroConfiguration.longBreakMinutes == 18 &&
              migrated.pomodoroConfiguration.longBreakInterval == 3 &&
              migrated.pomodoroConfiguration.rounds == 7 &&
              !migrated.pomodoroConfiguration.isUnlimited && migrated.pomodoroConfiguration.autoAdvance,
              "Adding seconds preserves every existing saved minute and cycle setting")
        check(migrated.pomodoroConfiguration.focusSeconds == 0 &&
              migrated.pomodoroConfiguration.shortBreakSeconds == 0 &&
              migrated.pomodoroConfiguration.longBreakSeconds == 0,
              "Old saved configurations default missing seconds to zero")
        var secondsConfiguration = PomodoroConfiguration()
        secondsConfiguration.focusMinutes = 1
        secondsConfiguration.focusSeconds = 7
        secondsConfiguration.shortBreakMinutes = 0
        secondsConfiguration.shortBreakSeconds = 9
        secondsConfiguration.longBreakMinutes = 0
        secondsConfiguration.longBreakSeconds = 21
        secondsConfiguration.longBreakInterval = 2
        secondsConfiguration.autoAdvance = true
        migrated.updatePomodoroConfiguration(secondsConfiguration)
        check(migrated.pomodoro.remaining == 67 &&
              migrated.pomodoroConfiguration.duration(for: .shortBreak) == 9 &&
              migrated.pomodoroConfiguration.duration(for: .longBreak) == 21,
              "All three phases use minute-plus-second durations, including sub-minute breaks")
        let restoredSeconds = IslandModel(playsAlertSound: false, timeToolDefaults: defaults)
        check(restoredSeconds.pomodoroConfiguration == secondsConfiguration && restoredSeconds.pomodoro.remaining == 67,
              "Custom seconds survive relaunch alongside minutes")
        var secondsSession = PomodoroSession(configuration: secondsConfiguration)
        secondsSession.start(at: now)
        secondsSession.refresh(at: now.addingTimeInterval(60))
        check(secondsSession.remaining == 7 && secondsSession.completedFocusCount == 0,
              "Focus does not complete until its extra seconds elapse")
        secondsSession.togglePause(at: now.addingTimeInterval(62))
        check(secondsSession.isPaused && secondsSession.remaining == 5,
              "Pausing preserves the second-precision remainder")
        secondsSession.togglePause(at: now.addingTimeInterval(100))
        check(secondsSession.refresh(at: now.addingTimeInterval(105)) == .focus &&
              secondsSession.phase == .shortBreak && secondsSession.remaining == 9 && secondsSession.isRunning,
              "Resume reaches the short break using its exact second duration")
        secondsSession.refresh(at: now.addingTimeInterval(114))
        check(secondsSession.phase == .focus && secondsSession.remaining == 67,
              "The short break advances after exactly nine seconds")
        secondsSession.refresh(at: now.addingTimeInterval(181))
        check(secondsSession.phase == .longBreak && secondsSession.remaining == 21,
              "The configured round interval starts the second-precision long break")
        secondsSession.refresh(at: now.addingTimeInterval(202))
        check(secondsSession.phase == .focus && secondsSession.remaining == 67,
              "The long break advances after exactly twenty-one seconds")
        var invalidSeconds = secondsConfiguration
        invalidSeconds.focusMinutes = 0
        invalidSeconds.focusSeconds = -10
        invalidSeconds.shortBreakSeconds = 100
        invalidSeconds.longBreakSeconds = -1
        let boundedSeconds = invalidSeconds.validated
        check(boundedSeconds.focusMinutes == 1 && boundedSeconds.focusSeconds == 0 &&
              boundedSeconds.shortBreakSeconds == 59 && boundedSeconds.longBreakMinutes == 1,
              "Seconds clamp to zero through fifty-nine and no phase can have zero duration")

        func alertModel(configuration: PomodoroConfiguration = .init()) -> IslandModel {
            let result = IslandModel(playsAlertSound: false, timeToolDefaults: defaults)
            result.updatePomodoroConfiguration(configuration)
            return result
        }
        let alertNow = Date()
        let focusAlert = alertModel()
        focusAlert.startPomodoro(at: alertNow.addingTimeInterval(-1500))
        focusAlert.refreshTimeTools(at: alertNow)

        let breakAlert = alertModel()
        breakAlert.startPomodoro(at: alertNow.addingTimeInterval(-1500))
        breakAlert.refreshTimeTools(at: alertNow)
        breakAlert.dismissTimerFinishedAlert()
        breakAlert.startPomodoro(at: alertNow.addingTimeInterval(-300))
        breakAlert.refreshTimeTools(at: alertNow)
        check(breakAlert.completionTitle == "休息结束", "Break completion uses the timed pomodoro alert")

        var singleRound = PomodoroConfiguration()
        singleRound.isUnlimited = false
        singleRound.rounds = 1
        let groupAlert = alertModel(configuration: singleRound)
        groupAlert.startPomodoro(at: alertNow.addingTimeInterval(-1500))
        groupAlert.refreshTimeTools(at: alertNow)
        check(groupAlert.completionTitle == "本组番茄钟完成", "Group completion uses the timed pomodoro alert")

        func queuedAlarm() -> IslandModel {
            let result = alertModel()
            result.startPomodoro(at: alertNow.addingTimeInterval(-1500))
            result.alarmTime = alertNow.addingTimeInterval(600)
            result.scheduleAlarm(at: alertNow)
            result.refreshTimeTools(at: alertNow.addingTimeInterval(601))
            return result
        }
        let automaticQueue = queuedAlarm()
        let manualQueue = queuedAlarm()
        manualQueue.dismissTimerFinishedAlert()
        let timerAlert = alertModel()
        timerAlert.setTimer(totalSeconds: 1)
        timerAlert.startTimer()
        timerAlert.refreshTimeTools(at: Date().addingTimeInterval(2))

        try await Task.sleep(for: .seconds(3))
        check(focusAlert.isTimerFinished && breakAlert.isTimerFinished && groupAlert.isTimerFinished,
              "Pomodoro alerts remain visible during their five-second presentation")
        try await Task.sleep(for: .seconds(2.3))
        check(!focusAlert.isTimerFinished && !focusAlert.isExpanded &&
              !breakAlert.isTimerFinished && !breakAlert.isExpanded &&
              !groupAlert.isTimerFinished && !groupAlert.isExpanded,
              "Focus, break and group alerts automatically collapse after five seconds")
        check(automaticQueue.isTimerFinished && automaticQueue.completionTitle == "闹钟响了",
              "Automatic dismissal reveals the next queued alarm")
        check(manualQueue.isTimerFinished && manualQueue.completionTitle == "闹钟响了",
              "A canceled pomodoro timeout must not dismiss a manually revealed alarm")
        check(timerAlert.isTimerFinished, "Ordinary timer completions still wait for acknowledgement")
        automaticQueue.dismissTimerFinishedAlert()
        manualQueue.dismissTimerFinishedAlert()
        timerAlert.dismissTimerFinishedAlert()

        model.selectedTimeTool = .pomodoro
        model.isPomodoroSettingsPresented = true
        model.selectedTimeTool = .alarm
        check(!model.isPomodoroSettingsPresented && !model.isTimeToolPopoverPresented,
              "Changing tools closes inline settings without opening an alarm popover")

        print("PASS: \(assertions) pomodoro, alarm and concurrent clock checks")
    }
}
