import Foundation
import Testing
@testable import GullfireKit

@Suite("Endless flight", .enabled(if: EnginePackages.available))
struct EndlessFlightTests {
    static func flight(_ dir: URL, seed: UInt64) throws -> EndlessFlight {
        let city = try CityPackage.open(directory: dir)
        return try #require(EndlessFlight(city: city, seed: seed))
    }

    /// The next loop, failing the test when none is made.
    static func next(_ flight: inout EndlessFlight) throws -> (route: Route, plan: RoutePlan) {
        let loop = flight.nextLoop()
        return try #require(loop)
    }

    @Test func aPackageWithoutStreetsHasNoEndlessFlight() throws {
        // ChicagoCity is built without streets.json. Skipped if that folder is absent or gains a street graph.
        let dir = PackageTests.root.appendingPathComponent("Cities/ChicagoCity", isDirectory: true)
        let hasPackage = FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path)
        let hasStreets = FileManager.default.fileExists(atPath: dir.appendingPathComponent("streets.json").path)
        guard hasPackage, !hasStreets else { return }
        let city = try CityPackage.open(directory: dir)
        #expect(EndlessFlight(city: city, seed: 1) == nil)
    }

    @Test(arguments: EnginePackages.dirs) func theSameSeedGivesTheSameFirstLoop(dir: URL) throws {
        var a = try Self.flight(dir, seed: 7)
        var b = try Self.flight(dir, seed: 7)
        let first = try Self.next(&a)
        let again = try Self.next(&b)
        #expect(first.plan.assembly.waypoints == again.plan.assembly.waypoints)
        #expect(first.route.samples == again.route.samples)
    }

    @Test(arguments: EnginePackages.dirs) func differentSeedsGiveDifferentLoops(dir: URL) throws {
        var firsts: [[Waypoint]] = []
        for seed in EnginePackages.seeds {
            var f = try Self.flight(dir, seed: seed)
            firsts.append(try Self.next(&f).plan.assembly.waypoints)
        }
        #expect(firsts.contains { $0 != firsts[0] }, "every seed made the same loop")
    }

    /// Adjacent seeds can make the same loop on a small graph (Vienna's 22 stretches do), so nextLoop() skips a seed whose
    /// stretches match the loop before it: every loop in a run differs from the one before.
    @Test(arguments: EnginePackages.dirs) func loopNumberAdvancesAndEveryLoopDiffersFromTheLast(dir: URL) throws {
        var f = try Self.flight(dir, seed: 3)
        #expect(f.loopNumber == 0)
        var lastNumber = 0
        var shapes: Set<[String]> = []
        var previous: [String] = []
        for _ in 0..<5 {
            let loop = try Self.next(&f)
            #expect(loop.plan.stretches.map { $0.stretch.id } != previous, "a loop repeated the one before it")
            previous = loop.plan.stretches.map { $0.stretch.id }
            #expect(f.loopNumber > lastNumber)
            #expect(loop.route.name == "Endless \(f.loopNumber)")
            shapes.insert(loop.plan.stretches.map { $0.stretch.id })
            lastNumber = f.loopNumber
        }
        #expect(shapes.count >= 2, "five loops in a row were all the same loop")
    }

    @Test(arguments: EnginePackages.dirs) func labelIsUppercasedAndNonEmpty(dir: URL) throws {
        var f = try Self.flight(dir, seed: 5)
        let loop = try Self.next(&f)
        let label = EndlessFlight.label(for: loop.plan)
        #expect(!label.isEmpty)
        #expect(label == label.uppercased())
        #expect(label.components(separatedBy: " / ").count <= 3)
    }

    @Test func lapCounterCountsAWrapAndIgnoresJitter() {
        var counter = LapCounter()
        var completed: [Bool] = []
        for i in 0..<100 {
            completed.append(counter.update(index: i, count: 100))
        }
        completed.append(counter.update(index: 3, count: 100))
        #expect(completed.filter { $0 }.count == 1)
        #expect(completed.last == true)
        #expect(counter.laps == 1)

        // A small backwards jitter (the index falls by 5) is not a lap.
        let jitter = [counter.update(index: 50, count: 100), counter.update(index: 45, count: 100)]
        #expect(jitter == [false, false])
        #expect(counter.laps == 1)

        counter.reset()
        #expect(counter.laps == 0)
        let afterReset = counter.update(index: 99, count: 100)
        #expect(!afterReset)
    }

    @Test(arguments: EnginePackages.dirs) func walkerStartingWithFixesTheFirstStretch(dir: URL) throws {
        let city = try CityPackage.open(directory: dir)
        let graph = try #require(try StreetGraph.load(from: dir))
        let js = JoinSettings.standard(for: city.manifest)
        var f = try Self.flight(dir, seed: 3)
        let loop = try Self.next(&f)
        let want = (id: loop.plan.stretches[1].stretch.id, reversed: loop.plan.stretches[1].reversed)
        var made = 0
        for seed in EnginePackages.seeds {
            guard let plan = RouteWalker.loop(graph: graph, obstacles: city, seed: seed, joinSettings: js, startingWith: want) else { continue }
            made += 1
            #expect(plan.stretches[0].stretch.id == want.id)
            #expect(plan.stretches[0].reversed == want.reversed)
            #expect(RouteChecker.check(plan, obstacles: city, joinSettings: js).isEmpty)
            let again = RouteWalker.loop(graph: graph, obstacles: city, seed: seed, joinSettings: js, startingWith: want)
            #expect(again?.assembly.waypoints == plan.assembly.waypoints, "same seed gave a different loop")
        }
        #expect(made >= 1, "no seed made a loop starting with the requested stretch")
        #expect(RouteWalker.loop(graph: graph, obstacles: city, seed: 1, joinSettings: js,
                                 startingWith: (id: "no-such-stretch", reversed: false)) == nil)
    }

    /// A pick: the first loop starts with the picked street in the picked direction, is checked, and advances the loop number.
    @Test(arguments: EnginePackages.dirs) func firstLoopStartsWithThePickedStreet(dir: URL) throws {
        let city = try CityPackage.open(directory: dir)
        let js = JoinSettings.standard(for: city.manifest)
        var source = try Self.flight(dir, seed: 3)
        let example = try Self.next(&source).plan.stretches[1]
        let want = (id: example.stretch.id, reversed: example.reversed)
        var made = 0
        for seed in EnginePackages.seeds {
            var f = try Self.flight(dir, seed: seed)
            guard let loop = f.firstLoop(startingWith: want.id, reversed: want.reversed) else { continue }
            made += 1
            #expect(loop.plan.stretches[0].stretch.id == want.id)
            #expect(loop.plan.stretches[0].reversed == want.reversed)
            #expect(loop.route.name == "Endless \(f.loopNumber)")
            #expect(f.loopNumber >= 1)
            #expect(RouteChecker.check(loop.plan, obstacles: city, joinSettings: js).isEmpty)
        }
        #expect(made >= 1, "no seed made a first loop starting with the picked street")
        var f = try Self.flight(dir, seed: 3)
        let before = f.loopNumber
        #expect(f.firstLoop(startingWith: "no-such-stretch", reversed: false) == nil)
        #expect(f.loopNumber == before + 12, "a failed pick should advance the loop number by 12")
    }

    /// A click's candidates are tried in order: a street that cannot start a loop falls through to a later one that can.
    @Test(arguments: EnginePackages.dirs) func firstLoopTryingFallsThroughToALaterStreet(dir: URL) throws {
        let base = try Self.flight(dir, seed: 3)
        let graph = try #require(try StreetGraph.load(from: dir))
        // The first stretch (forward) that cannot start a loop alone. Skipped when every stretch can.
        var failing: (id: String, reversed: Bool)?
        for stretch in graph.stretches {
            var solo = base
            if solo.firstLoop(startingWith: stretch.id, reversed: false) == nil {
                failing = (id: stretch.id, reversed: false)
                break
            }
        }
        guard let failing else { return }
        // The state after the failing candidate, as firstLoop(trying:) leaves it before the next one.
        var afterFailing = base
        _ = afterFailing.firstLoop(startingWith: failing.id, reversed: failing.reversed)
        var working: (id: String, reversed: Bool)?
        for stretch in graph.stretches where stretch.id != failing.id {
            var attempt = afterFailing
            if attempt.firstLoop(startingWith: stretch.id, reversed: false) != nil {
                working = (id: stretch.id, reversed: false)
                break
            }
        }
        guard let working else { return }

        var f = base
        let made = f.firstLoop(trying: [failing, working])
        let loop = try #require(made)
        #expect(loop.usedIndex == 1)
        #expect(loop.plan.stretches[0].stretch.id == working.id)
        #expect(loop.plan.stretches[0].reversed == working.reversed)
        #expect(loop.route.name == "Endless \(f.loopNumber)")
        let city = try CityPackage.open(directory: dir)
        let js = JoinSettings.standard(for: city.manifest)
        #expect(RouteChecker.check(loop.plan, obstacles: city, joinSettings: js).isEmpty)

        var alone = base
        let aloneLoop = alone.firstLoop(trying: [failing])
        #expect(aloneLoop == nil)
        var none = base
        let noneLoop = none.firstLoop(trying: [])
        #expect(noneLoop == nil)
    }

    @Test(arguments: EnginePackages.dirs) func nextLoopAfterStartsWithTheOldSecondStretch(dir: URL) throws {
        let city = try CityPackage.open(directory: dir)
        let js = JoinSettings.standard(for: city.manifest)
        var f = try Self.flight(dir, seed: 11)
        let first = try Self.next(&f)
        let before = f.loopNumber
        let chainedOrNil = f.nextLoop(after: first.plan)
        let chained = try #require(chainedOrNil)
        #expect(f.loopNumber > before)
        #expect(chained.route.name == "Endless \(f.loopNumber)")
        #expect(chained.plan.stretches[0].stretch.id == first.plan.stretches[1].stretch.id)
        #expect(chained.plan.stretches[0].reversed == first.plan.stretches[1].reversed)
        #expect(RouteChecker.check(chained.plan, obstacles: city, joinSettings: js).isEmpty)
        let swap = EndlessFlight.swapIndex(route: first.route, plan: first.plan)
        #expect(swap >= 0 && swap < first.route.count)
    }

    @Test func swapTriggerFiresOnceOverASweepAndIgnoresJitter() {
        var trigger = SwapTrigger(swapIndex: 50, count: 100)
        var fired: [Int] = []
        for i in 0..<100 {
            if trigger.update(index: i) { fired.append(i) }
        }
        #expect(fired == [50])
        // Jitter around the swap point and a backward step of 5 after it do not fire it again.
        let after = [trigger.update(index: 45), trigger.update(index: 50), trigger.update(index: 55),
                     trigger.update(index: 50), trigger.update(index: 47), trigger.update(index: 52)]
        #expect(after.allSatisfy { !$0 })
    }

    @Test func swapTriggerIgnoresARouteThatStartsPastTheSwapAndFiresAgainAfterReset() {
        var trigger = SwapTrigger(swapIndex: 50, count: 100)
        // A route starting past the swap point does not fire until it has been below and come back up.
        let past = [trigger.update(index: 60), trigger.update(index: 55)]
        #expect(past == [false, false])
        trigger.reset(swapIndex: 50, count: 100)
        var fired = 0
        for i in 0..<100 {
            if trigger.update(index: i) { fired += 1 }
        }
        #expect(fired == 1)
        trigger.reset(swapIndex: 20, count: 100)
        var again: [Int] = []
        for i in 0..<100 {
            if trigger.update(index: i) { again.append(i) }
        }
        #expect(again == [20])
    }
}

@Suite("Marked streets are real", .enabled(if: EnginePackages.available))
struct MarkedStreetTests {
    /// `gullfire-pack loops` writes which streets can start a loop. A street it marks as working must make a loop, in the
    /// direction it marks. (Marks that say no are not re-checked here: a failing walk is slow in a Debug build.)
    @Test(arguments: EnginePackages.dirs) func marksThatSayYesMakeALoop(dir: URL) throws {
        let city = try CityPackage.open(directory: dir)
        let graph = try #require(try StreetGraph.load(from: dir))
        let js = JoinSettings.standard(for: city.manifest)
        let marked = graph.stretches.enumerated().filter { $0.element.loops != nil && $0.element.canStartAny }
        try #require(!marked.isEmpty, "\(dir.lastPathComponent) has no marks: run gullfire-pack loops")
        var checked = 0
        for (i, st) in marked.prefix(40) where i % 4 == 0 {
            let reversed = !st.canStart(reversed: false)
            let works = (1...3).contains { seed in
                RouteWalker.loop(graph: graph, obstacles: city, seed: UInt64(seed), joinSettings: js, startingWith: (id: st.id, reversed: reversed)) != nil
            }
            #expect(works, "\(st.id) is marked as able to start a loop (reversed \(reversed)) but the walker could not")
            checked += 1
        }
        #expect(checked >= 3)
    }
}
