import Foundation

@main struct RepeatingAlarmTests {
    @MainActor static func main() {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { fatalError("FAIL: \(message)") }
        }
        func pump(_ duration: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(duration)) }

        var plays = 0
        var stops = 0
        var playedAt: [Date] = []
        let alarm = RepeatingAlarm(interval: 0.04, play: {
            plays += 1
            playedAt.append(Date())
        }, stopAudio: { stops += 1 })

        expect(!alarm.isActive, "alarm begins inactive")
        alarm.start()
        expect(alarm.isActive && plays == 1, "first sound plays immediately")
        alarm.start()
        expect(plays == 1, "repeated start does not replay immediately")
        pump(0.19)
        expect(plays >= 4, "sound repeats at least three times without user acknowledgement")
        expect(plays <= 6, "repeated start does not create a second timer")
        let intervals = zip(playedAt.dropFirst(), playedAt).map { $0.timeIntervalSince($1) }
        expect(intervals.allSatisfy { $0 > 0.02 }, "ticks are not duplicated or clustered")

        alarm.stop()
        let stoppedCount = plays
        expect(!alarm.isActive && stops == 1, "stop clears active state and stops current audio")
        pump(0.13)
        expect(plays == stoppedCount, "no more sounds occur after stop")
        alarm.stop()
        expect(stops == 1, "stop is idempotent")

        alarm.start()
        expect(alarm.isActive && plays == stoppedCount + 1, "a new reminder can start after acknowledgement")
        pump(0.10)
        expect(plays >= stoppedCount + 3, "restarted alarm keeps repeating")
        alarm.stop()
        let finalCount = plays
        pump(0.10)
        expect(plays == finalCount && stops == 2, "restarted alarm also stops cleanly")
        print("PASS: \(checks) repeating-alarm checks (silent callbacks)")
    }
}
