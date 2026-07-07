import Foundation

/// Pure generator behind `DemoEventScript`. Content is driven entirely by `seed` and `startedAt`
/// on an internal virtual clock, so two scenarios built with the same inputs produce identical
/// batch sequences regardless of when `nextBatch` is actually called.
public struct DemoScenario: Sendable {
    private struct DemoSession: Sendable {
        var key: SessionKey
        var handoffOpen = false
        var bugOpen = false
    }

    private enum PendingKind: Sendable {
        case handoffReturn(sessionIndex: Int, success: Bool)
        case bugResolve(sessionIndex: Int)
    }

    private struct Pending: Sendable {
        var due: Double
        var kind: PendingKind
    }

    private static let projectNames = ["Reef", "Sonar", "Kelp", "Tide", "Coral"]
    private static let randomStatuses: [AgentStatus] = [.planning, .coding, .testing, .searching, .reviewing]
    private static let taskSummaries = [
        "Polished the fin physics",
        "Tuned the bubble timing",
        "Refactored FishNode",
        "Sharpened the reef shader",
        "Trimmed dead kelp from the scene",
    ]
    private static let failureReasons = [
        "Type check failed",
        "Snapshot mismatch",
        "Merge conflict in the reef",
    ]
    private static let handoffDescriptions = [
        "Scout the schema",
        "Survey the reef",
        "Chart the depths",
    ]

    private static func thoughtPool(for status: AgentStatus) -> [String] {
        switch status {
        case .planning:
            ["Sketching a plan…", "Mapping the currents…", "Outlining next steps…"]
        case .coding:
            ["Editing FishNode.swift", "Wiring up AquariumScene…", "Polishing the reef shader"]
        case .testing:
            ["Running tests…", "Checking 34 specs…", "Rerunning the suite…"]
        case .searching:
            ["Grepping the reef…", "Diving for references…", "Scanning the kelp forest…"]
        case .reviewing:
            ["Rereading the diff…", "Combing through changes…", "Double-checking edge cases…"]
        default:
            ["Thinking…"]
        }
    }

    private var rng: SplitMix64
    private let startedAt: Date
    private var started = false
    /// Seconds since the first batch on the scenario's virtual clock.
    private var clock: Double = 0
    private var statusDue: Double = 0
    private var taskDue: Double = 0
    private var handoffDue: Double = 0
    private var bugDue: Double = 0
    private var pending: [Pending] = []
    private var sessions: [DemoSession] = []

    public init(seed: UInt64, startedAt: Date) {
        self.rng = SplitMix64(seed: seed)
        self.startedAt = startedAt
    }

    /// Pure: returns the next batch and the delay before it, advancing internal rng state.
    /// `now` does not affect generation; the batch content follows the virtual clock.
    public mutating func nextBatch(now: Date) -> (delay: Duration, events: [AgentEvent]) {
        guard started else { return startBatch() }

        var dues = [statusDue, taskDue, handoffDue, bugDue]
        if let next = pending.first {
            dues.append(next.due)
        }
        let nextDue = dues.min() ?? clock
        let delaySeconds = max(1.0, nextDue - clock)
        clock += delaySeconds

        var events: [AgentEvent] = []
        while let next = pending.first, next.due <= clock {
            pending.removeFirst()
            resolve(next.kind, into: &events)
        }
        if statusDue <= clock {
            fireStatusChange(into: &events)
            statusDue = clock + draw(2...6)
        }
        if taskDue <= clock {
            fireTask(into: &events)
            taskDue = clock + draw(8...14)
        }
        if handoffDue <= clock {
            fireHandoff(into: &events)
            handoffDue = clock + draw(25...40)
        }
        if bugDue <= clock {
            fireBug(into: &events)
            bugDue = clock + draw(90...150)
        }
        return (.seconds(delaySeconds), events)
    }

    private mutating func startBatch() -> (delay: Duration, events: [AgentEvent]) {
        started = true
        var events: [AgentEvent] = []
        for (index, provider) in AgentProvider.allCases.enumerated() {
            let key = SessionKey(provider: provider, sessionID: "demo-\(provider.rawValue)")
            let descriptor = SessionDescriptor(
                key: key,
                projectKey: "demo/\(provider.rawValue)",
                projectDisplayName: Self.projectNames[index % Self.projectNames.count],
                isSubagent: false,
                startedAt: startedAt
            )
            sessions.append(DemoSession(key: key))
            events.append(.sessionStarted(descriptor))
        }
        statusDue = draw(2...6)
        taskDue = draw(8...14)
        handoffDue = draw(25...40)
        bugDue = draw(90...150)
        return (.seconds(1), events)
    }

    private mutating func fireStatusChange(into events: inout [AgentEvent]) {
        guard let index = pickSessionIndex(where: { !$0.handoffOpen && !$0.bugOpen }) else { return }
        let status = pick(Self.randomStatuses)
        let key = sessions[index].key
        events.append(.statusChanged(key, status))
        events.append(.thought(key, message: pick(Self.thoughtPool(for: status))))
    }

    private mutating func fireTask(into events: inout [AgentEvent]) {
        guard let index = pickSessionIndex(where: { !$0.handoffOpen && !$0.bugOpen }) else { return }
        let key = sessions[index].key
        if rng.next() % 6 == 0 {
            events.append(.taskFailed(key, reason: pick(Self.failureReasons)))
        } else {
            events.append(.taskCompleted(key, domain: pick(MemoryDomain.allCases), summary: pick(Self.taskSummaries)))
        }
    }

    private mutating func fireHandoff(into events: inout [AgentEvent]) {
        guard let index = pickSessionIndex(where: { !$0.handoffOpen && !$0.bugOpen }) else { return }
        sessions[index].handoffOpen = true
        let key = sessions[index].key
        events.append(.handoff(key, subagentType: "Explore", description: pick(Self.handoffDescriptions)))
        events.append(.statusChanged(key, .handingOff))
        let success = rng.next() % 6 != 0
        schedule(Pending(due: clock + draw(4...8), kind: .handoffReturn(sessionIndex: index, success: success)))
    }

    private mutating func fireBug(into events: inout [AgentEvent]) {
        guard let index = pickSessionIndex(where: { !$0.handoffOpen && !$0.bugOpen }) else { return }
        sessions[index].bugOpen = true
        let key = sessions[index].key
        events.append(.bugDetected(key, evidence: "Tests failed: 2 of 34"))
        events.append(.statusChanged(key, .fixingBug))
        schedule(Pending(due: clock + draw(15...25), kind: .bugResolve(sessionIndex: index)))
    }

    private mutating func resolve(_ kind: PendingKind, into events: inout [AgentEvent]) {
        switch kind {
        case .handoffReturn(let index, let success):
            sessions[index].handoffOpen = false
            let key = sessions[index].key
            events.append(.handoffReturned(key, success: success))
            events.append(.statusChanged(key, success ? .coding : .reviewing))
        case .bugResolve(let index):
            sessions[index].bugOpen = false
            let key = sessions[index].key
            events.append(.bugResolved(key))
            events.append(.statusChanged(key, .celebrating))
        }
    }

    private mutating func schedule(_ item: Pending) {
        let index = pending.firstIndex { $0.due > item.due } ?? pending.endIndex
        pending.insert(item, at: index)
    }

    private mutating func pickSessionIndex(where isEligible: (DemoSession) -> Bool) -> Int? {
        let eligible = sessions.indices.filter { isEligible(sessions[$0]) }
        guard !eligible.isEmpty else { return nil }
        return pick(eligible)
    }

    private mutating func pick<Element>(_ elements: [Element]) -> Element {
        elements[Int(rng.next() % UInt64(elements.count))]
    }

    private mutating func draw(_ range: ClosedRange<Double>) -> Double {
        rng.double(in: range.lowerBound..<range.upperBound)
    }
}

/// Deterministic, pleasant synthetic activity stream for first-run/demo mode.
public actor DemoEventScript: AgentEventStreaming {
    private let seed: UInt64
    private let speed: Double

    /// `speed > 1` compresses delays (useful for previews and tests).
    public init(seed: UInt64 = 0xF15B, speed: Double = 1.0) {
        self.seed = seed
        self.speed = max(speed, 0.001)
    }

    public nonisolated func events() -> AsyncStream<AgentEvent> {
        let seed = seed
        let speed = speed
        return AsyncStream { continuation in
            let task = Task {
                var scenario = DemoScenario(seed: seed, startedAt: Date())
                while !Task.isCancelled {
                    let (delay, batch) = scenario.nextBatch(now: Date())
                    do {
                        try await Task.sleep(for: delay / speed)
                    } catch {
                        break
                    }
                    for event in batch {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
