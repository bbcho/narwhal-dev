import Testing
@testable import NarwhalAppSupport

@Suite("Config reload model")
struct ConfigReloadModelTests {
    @Test("Config event target matches only config file and containing directory")
    func configEventTargetMatchesOnlyConfigFileAndContainingDirectory() {
        let target = ConfigWatchTarget(
            configPath: "/Users/ben/.config/narwhal/init.lua",
            directoryPath: "/Users/ben/.config/narwhal"
        )

        #expect(configChangeEventTouchesTarget(
            path: "/Users/ben/.config/narwhal/init.lua",
            target: target
        ))
        #expect(configChangeEventTouchesTarget(
            path: "/Users/ben/.config/narwhal",
            target: target
        ))
        #expect(!configChangeEventTouchesTarget(
            path: "/Users/ben/.config/narwhal/other.lua",
            target: target
        ))
        #expect(!configChangeEventTouchesTarget(
            path: "/Users/ben/.config",
            target: target
        ))
    }

    @Test("Scheduling config reload replaces pending generation")
    func schedulingConfigReloadReplacesPendingGeneration() {
        let first = scheduleConfigReload(in: .empty)
        let second = scheduleConfigReload(in: first.state)

        #expect(first.generation == 1)
        #expect(first.state == ConfigReloadDebounceState(nextGeneration: 2, pendingGeneration: 1))
        #expect(second.generation == 2)
        #expect(second.state == ConfigReloadDebounceState(nextGeneration: 3, pendingGeneration: 2))
    }

    @Test("Timer ignores stale generation and fires current generation once")
    func timerIgnoresStaleGenerationAndFiresCurrentGenerationOnce() {
        let first = scheduleConfigReload(in: .empty)
        let second = scheduleConfigReload(in: first.state)

        let staleFire = fireConfigReloadTimer(generation: first.generation, in: second.state)
        let currentFire = fireConfigReloadTimer(generation: second.generation, in: staleFire.state)
        let repeatFire = fireConfigReloadTimer(generation: second.generation, in: currentFire.state)

        #expect(staleFire.state == second.state)
        #expect(staleFire.decision == .stale(pendingGeneration: second.generation))
        #expect(currentFire.state == ConfigReloadDebounceState(nextGeneration: 3, pendingGeneration: nil))
        #expect(currentFire.decision == .reload)
        #expect(repeatFire.state == currentFire.state)
        #expect(repeatFire.decision == .idle)
    }

    @Test("Cancel clears pending config reload without rewinding generation")
    func cancelClearsPendingConfigReloadWithoutRewindingGeneration() {
        let scheduled = scheduleConfigReload(in: .empty)

        let canceled = cancelConfigReload(in: scheduled.state)
        let fired = fireConfigReloadTimer(generation: scheduled.generation, in: canceled)

        #expect(canceled == ConfigReloadDebounceState(nextGeneration: 2, pendingGeneration: nil))
        #expect(fired.state == canceled)
        #expect(fired.decision == .idle)
    }
}
