import Foundation

@main struct RepeatingAlarmTests {
    @MainActor static func main() {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { fatalError("FAIL: \(message)") }
        }
        func pump(_ duration: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(duration)) }
        func waitForCallbacks(_ condition: () -> Bool) {
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while !condition() && ProcessInfo.processInfo.systemUptime < deadline { pump(0.01) }
        }

        var plays = 0
        var stops = 0
        let alarm = RepeatingAlarm(interval: 0.04, play: {
            plays += 1
        }, stopAudio: { stops += 1 })

        expect(!alarm.isActive, "alarm begins inactive")
        let startedAt = ProcessInfo.processInfo.systemUptime
        alarm.start()
        expect(alarm.isActive && plays == 1, "first sound plays immediately")
        alarm.start()
        expect(plays == 1, "repeated start does not replay immediately")
        waitForCallbacks { plays >= 6 }
        expect(plays >= 6, "sound keeps repeating without user acknowledgement")
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        expect(plays - 1 <= Int(elapsed / 0.04) + 1, "repeated start does not double the timer rate")
        let repeatingCount = plays
        alarm.start()
        expect(plays == repeatingCount, "start remains idempotent after timer callbacks")

        alarm.stop()
        let stoppedCount = plays
        expect(!alarm.isActive && stops == 1, "stop clears active state and stops current audio")
        pump(0.13)
        expect(plays == stoppedCount, "no more sounds occur after stop")
        alarm.stop()
        expect(stops == 1, "stop is idempotent")

        alarm.start()
        expect(alarm.isActive && plays == stoppedCount + 1, "a new reminder can start after acknowledgement")
        waitForCallbacks { plays >= stoppedCount + 3 }
        expect(plays >= stoppedCount + 3, "restarted alarm keeps repeating")
        alarm.stop()
        let finalCount = plays
        pump(0.10)
        expect(plays == finalCount && stops == 2, "restarted alarm also stops cleanly")
        print("PASS: \(checks) repeating-alarm checks (silent callbacks)")
    }
}
