import Testing
@testable import ShoutingSpikeLib

struct AdaptiveNoiseFloorTests {

    @Test func constantInput_emitsNoEvents() {
        var anf = AdaptiveNoiseFloor()
        var ticks: [Tick] = []
        for k in 0..<300 {
            let tick = anf.process(sample: -40.0, atTimeSeconds: Double(k) * 0.1)
            ticks.append(tick)
        }
        #expect(anf.events.isEmpty)
        let postWarmup = ticks.dropFirst(10)
        for tick in postWarmup {
            #expect(abs(tick.floorDBFS - (-40.0)) < 0.01)
        }
    }

    @Test func sustainedSpike_emitsOneEvent() {
        var anf = AdaptiveNoiseFloor()
        for k in 0..<50 {
            _ = anf.process(sample: -60.0, atTimeSeconds: Double(k) * 0.1)
        }
        for k in 50..<60 {
            _ = anf.process(sample: -20.0, atTimeSeconds: Double(k) * 0.1)
        }
        for k in 60..<110 {
            _ = anf.process(sample: -60.0, atTimeSeconds: Double(k) * 0.1)
        }
        #expect(anf.events.count == 1)
        #expect(abs(anf.events[0].onsetTimeSeconds - 5.0) < 0.05)
    }

    @Test func briefSpike_emitsNoEvents() {
        var anf = AdaptiveNoiseFloor()
        for k in 0..<50 {
            _ = anf.process(sample: -60.0, atTimeSeconds: Double(k) * 0.1)
        }
        for k in 50..<53 {
            _ = anf.process(sample: -20.0, atTimeSeconds: Double(k) * 0.1)
        }
        for k in 53..<103 {
            _ = anf.process(sample: -60.0, atTimeSeconds: Double(k) * 0.1)
        }
        #expect(anf.events.isEmpty)
    }

    @Test func floorAdapts_stepChange() {
        var anf = AdaptiveNoiseFloor()
        var ticks: [Tick] = []
        for k in 0..<50 {
            let tick = anf.process(sample: -60.0, atTimeSeconds: Double(k) * 0.1)
            ticks.append(tick)
        }
        for k in 50..<150 {
            let tick = anf.process(sample: -40.0, atTimeSeconds: Double(k) * 0.1)
            ticks.append(tick)
        }
        #expect(anf.events.isEmpty)
        let adaptationWindow = ticks[50..<100]
        let adapted = adaptationWindow.contains { abs($0.floorDBFS - (-40.0)) <= 3.0 }
        #expect(adapted)
    }

    @Test func cooldownEnforced() {
        var anf = AdaptiveNoiseFloor()
        for k in 0..<10 {
            _ = anf.process(sample: -60.0, atTimeSeconds: Double(k) * 0.1)
        }
        for k in 10..<110 {
            _ = anf.process(sample: -20.0, atTimeSeconds: Double(k) * 0.1)
        }
        #expect(anf.events.count == 1)
        #expect(abs(anf.events[0].onsetTimeSeconds - 1.0) < 0.05)
    }

    @Test func bufferWarmup_noEarlyEvents() {
        var anf = AdaptiveNoiseFloor()
        for k in 0..<4 {
            _ = anf.process(sample: -20.0, atTimeSeconds: Double(k) * 0.1)
        }
        #expect(anf.events.isEmpty)
    }

    @Test func silentInput_noCrash() {
        var anf = AdaptiveNoiseFloor()
        var ticks: [Tick] = []
        for k in 0..<300 {
            let tick = anf.process(sample: -140.0, atTimeSeconds: Double(k) * 0.1)
            ticks.append(tick)
        }
        #expect(anf.events.isEmpty)
        let postWarmup = ticks.dropFirst(10)
        for tick in postWarmup {
            #expect(tick.floorDBFS.isFinite)
            #expect(tick.thresholdDBFS.isFinite)
            #expect(!tick.floorDBFS.isNaN)
            #expect(!tick.thresholdDBFS.isNaN)
        }
    }
}
