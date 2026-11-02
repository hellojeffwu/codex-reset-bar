import AppKit

@MainActor final class RepeatingAlarm {
    private(set) var isActive = false
    private let interval: TimeInterval
    private let playAudio: () -> Void
    private let stopAudio: () -> Void
    private var timer: Timer?

    convenience init() {
        let sound = NSSound(named: "Glass")
        self.init(interval: 5, play: {
            guard let sound, !sound.isPlaying else { return }
            sound.currentTime = 0
            sound.play()
        }, stopAudio: { sound?.stop() })
    }

    // The injected callbacks keep timing checks silent and independent of speakers.
    init(interval: TimeInterval, play: @escaping () -> Void, stopAudio: @escaping () -> Void) {
        self.interval = interval
        self.playAudio = play
        self.stopAudio = stopAudio
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        let repeating = Timer(timeInterval: interval, repeats: true) { [weak self] fired in
            MainActor.assumeIsolated {
                guard let self, self.isActive, self.timer === fired else { return }
                self.playAudio()
            }
        }
        timer = repeating
        RunLoop.main.add(repeating, forMode: .common)
        playAudio()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        timer?.invalidate()
        timer = nil
        stopAudio()
    }

    deinit {
        timer?.invalidate()
        stopAudio()
    }
}
