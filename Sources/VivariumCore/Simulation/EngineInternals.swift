import Foundation

/// Event application: sessions→fish binding, statuses, thoughts, food, pearls, shark.
enum EngineEventHandler {
    static func apply(
        _ event: AgentEvent,
        to state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date,
        rng: inout SplitMix64
    ) {
        switch event {
        case .sessionStarted(let descriptor):
            applySessionStarted(descriptor, to: &state, events: &events, now: now)
        case .sessionUpdated(let descriptor):
            applySessionUpdated(descriptor, to: &state, now: now)
        case .sessionEnded(let key, at: _):
            applySessionEnded(key, to: &state, events: &events, now: now)
        case .statusChanged(let key, let status):
            applyStatusChanged(key, status, to: &state, events: &events, now: now)
        case .thought(let key, let message):
            applyThought(key, message, to: &state, events: &events, now: now)
        case .taskCompleted(let key, let domain, let summary):
            applyTaskCompleted(key, domain: domain, summary: summary, to: &state, events: &events, now: now, rng: &rng)
        case .taskFailed(let key, let reason):
            applyTaskFailed(key, reason: reason, to: &state, events: &events, now: now)
        case .waitingForUser(let key, _):
            if let fi = EngineSupport.boundFishIndex(forKey: key, in: state) {
                EngineSupport.setStatus(.waiting, fishAt: fi, in: &state, events: &events)
            }
        case .handoff(let key, let subagentType, _):
            applyHandoff(key, subagentType: subagentType, to: &state, events: &events, now: now)
        case .handoffReturned(let key, let success):
            applyHandoffReturned(key, success: success, to: &state, events: &events, now: now)
        case .bugDetected(let key, let evidence):
            applyBugDetected(key, evidence: evidence, to: &state, events: &events, now: now)
        case .bugResolved(let key):
            applyBugResolved(key, to: &state, events: &events, now: now)
        case .providerActivity(let provider, _, let level, _):
            applyProviderActivity(provider, level: level, to: &state, events: &events, now: now)
        }
    }

    static func applyIntent(
        _ intent: SceneIntent,
        to state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date
    ) {
        switch intent {
        case .foodEaten(let id, let by):
            guard let pi = state.food.firstIndex(where: { $0.id == id }),
                  state.food[pi].fish == by,
                  state.food[pi].state == .falling || state.food[pi].state == .available,
                  let fi = EngineSupport.fishIndex(of: by, in: state)
            else { return }
            state.food[pi].state = .eaten
            if state.fish[fi].isResident {
                let newSize = min(1.45, state.fish[fi].size + 0.055)
                if newSize != state.fish[fi].size {
                    state.fish[fi].size = newSize
                    events.append(.fishGrew(by, newSize: newSize))
                }
            }
            let newFatigue = max(0, state.fish[fi].fatigue - 0.12)
            if newFatigue != state.fish[fi].fatigue {
                state.fish[fi].fatigue = newFatigue
                events.append(.fishFatigueChanged(by, newFatigue))
            }
            state.fish[fi].thought = ThoughtBubble(message: "Yum!", expiresAt: now.addingTimeInterval(1.5))
            events.append(.fishThought(by, "Yum!"))
        case .fishSelected:
            break
        }
    }

    // MARK: - Sessions

    private static func applySessionStarted(
        _ descriptor: SessionDescriptor,
        to state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date
    ) {
        guard !descriptor.isSubagent else { return }
        // Duplicate start for a session we already track behaves like an update.
        guard EngineSupport.bindingIndex(forKey: descriptor.key, in: state) == nil else {
            applySessionUpdated(descriptor, to: &state, now: now)
            return
        }
        let provider = descriptor.key.provider
        let residentID = FishID.resident(provider: provider, projectKey: descriptor.projectKey)
        let residentIsBound = state.sessions.contains { $0.fishID == residentID }
        let fishID: FishID
        if !residentIsBound {
            fishID = residentID
            if let fi = EngineSupport.fishIndex(of: residentID, in: state) {
                state.fish[fi].sessionCount += 1
                state.fish[fi].currentSessionTitle = descriptor.title
                state.fish[fi].gitBranch = descriptor.gitBranch
                state.fish[fi].model = descriptor.model
                state.fish[fi].lastActiveAt = now
                EngineSupport.setStatus(.planning, fishAt: fi, in: &state, events: &events)
            } else if let di = state.dormant.firstIndex(where: { $0.id == residentID }) {
                // Revive a dormant memory fish with its accumulated growth and expertise.
                var revived = state.dormant.remove(at: di)
                revived.sessionCount += 1
                revived.currentSessionTitle = descriptor.title
                revived.gitBranch = descriptor.gitBranch
                revived.model = descriptor.model
                revived.lastActiveAt = now
                revived.status = .planning
                revived.thought = nil
                state.fish.append(revived)
                events.append(.fishAdded(revived))
            } else {
                let fish = FishState(
                    id: residentID,
                    provider: provider,
                    displayName: EngineSupport.displayName(for: provider, project: descriptor.projectDisplayName),
                    projectKey: descriptor.projectKey,
                    isResident: true,
                    status: .planning,
                    lastActiveAt: now,
                    createdAt: now,
                    sessionCount: 1,
                    currentSessionTitle: descriptor.title,
                    gitBranch: descriptor.gitBranch,
                    model: descriptor.model
                )
                state.fish.append(fish)
                events.append(.fishAdded(fish))
            }
        } else {
            let ephemeralID = FishID.ephemeral(provider: provider, sessionID: descriptor.key.sessionID)
            fishID = ephemeralID
            if EngineSupport.fishIndex(of: ephemeralID, in: state) == nil {
                let fish = FishState(
                    id: ephemeralID,
                    provider: provider,
                    displayName: EngineSupport.displayName(for: provider, project: descriptor.projectDisplayName),
                    projectKey: descriptor.projectKey,
                    isResident: false,
                    status: .planning,
                    size: 0.85,
                    lastActiveAt: now,
                    createdAt: now,
                    sessionCount: 1,
                    currentSessionTitle: descriptor.title,
                    gitBranch: descriptor.gitBranch,
                    model: descriptor.model
                )
                state.fish.append(fish)
                events.append(.fishAdded(fish))
            }
        }
        state.sessions.append(SessionBinding(key: descriptor.key, fishID: fishID, descriptor: descriptor))
        EngineSupport.log(
            "\(provider.displayName) started on \(descriptor.projectDisplayName)",
            in: &state, now: now
        )
    }

    private static func applySessionUpdated(
        _ descriptor: SessionDescriptor,
        to state: inout EcosystemState,
        now: Date
    ) {
        guard let bi = EngineSupport.bindingIndex(forKey: descriptor.key, in: state) else { return }
        state.sessions[bi].descriptor = descriptor
        guard let fi = EngineSupport.fishIndex(of: state.sessions[bi].fishID, in: state) else { return }
        let name = EngineSupport.displayName(for: descriptor.key.provider, project: descriptor.projectDisplayName)
        if state.fish[fi].currentSessionTitle != descriptor.title { state.fish[fi].currentSessionTitle = descriptor.title }
        if state.fish[fi].gitBranch != descriptor.gitBranch { state.fish[fi].gitBranch = descriptor.gitBranch }
        if state.fish[fi].model != descriptor.model { state.fish[fi].model = descriptor.model }
        if state.fish[fi].displayName != name { state.fish[fi].displayName = name }
    }

    private static func applySessionEnded(
        _ key: SessionKey,
        to state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date
    ) {
        guard let bi = EngineSupport.bindingIndex(forKey: key, in: state) else { return }
        let binding = state.sessions.remove(at: bi)
        if let fi = EngineSupport.fishIndex(of: binding.fishID, in: state) {
            if state.fish[fi].isResident {
                // Preserve the memory fish's stats in dormant storage, then remove it from the tank
                // so fish are only visible while their agent is actually running.
                var dorm = state.fish[fi]
                dorm.status = .resting
                dorm.activityLevel = .sleeping
                dorm.thought = nil
                dorm.currentSessionTitle = nil
                state.dormant.removeAll { $0.id == dorm.id }
                state.dormant.append(dorm)
            }
            state.fish.remove(at: fi)
            events.append(.fishRemoved(binding.fishID))
        }
        EngineSupport.log(
            "\(key.provider.displayName) ended a session on \(binding.descriptor.projectDisplayName)",
            in: &state, now: now
        )
    }

    private static func applyStatusChanged(
        _ key: SessionKey,
        _ status: AgentStatus,
        to state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date
    ) {
        guard let fi = EngineSupport.boundFishIndex(forKey: key, in: state) else { return }
        if status.isActive { state.fish[fi].lastActiveAt = now }
        EngineSupport.setStatus(status, fishAt: fi, in: &state, events: &events)
    }

    private static func applyThought(
        _ key: SessionKey,
        _ message: String,
        to state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date
    ) {
        guard let fi = EngineSupport.boundFishIndex(forKey: key, in: state) else { return }
        state.fish[fi].thought = ThoughtBubble(message: message, expiresAt: now.addingTimeInterval(3))
        events.append(.fishThought(state.fish[fi].id, message))
    }

    // MARK: - Tasks

    private static func applyTaskCompleted(
        _ key: SessionKey,
        domain: MemoryDomain?,
        summary: String?,
        to state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date,
        rng: inout SplitMix64
    ) {
        guard let fi = EngineSupport.boundFishIndex(forKey: key, in: state) else { return }
        let fishID = state.fish[fi].id
        state.fish[fi].tasksCompleted += 1
        state.totalTasksCompleted += 1
        state.fish[fi].lastActiveAt = now

        EngineSupport.dropFood(for: fishID, in: &state, events: &events, now: now)

        // Memory: a new domain starts at level 1; an existing one levels up on every 5th
        // completed task of the fish (approximation of per-domain counts — see module notes).
        if let domain {
            if let mi = state.fish[fi].memory.firstIndex(where: { $0.domain == domain }) {
                if state.fish[fi].tasksCompleted % 5 == 0, state.fish[fi].memory[mi].level < 5 {
                    state.fish[fi].memory[mi].level += 1
                    events.append(.fishMemoryChanged(fishID, state.fish[fi].memory))
                }
            } else {
                state.fish[fi].memory.append(MemoryTrait(domain: domain, level: 1))
                events.append(.fishMemoryChanged(fishID, state.fish[fi].memory))
            }
        }

        // 1-in-1000 golden visitor. The roll always consumes rng for reproducibility.
        let roll = rng.unit()
        if roll < 0.001, state.rareVisitor == nil {
            let visitor = RareVisitor(kind: .goldenFish, appearedAt: now, until: now.addingTimeInterval(45))
            state.rareVisitor = visitor
            events.append(.rareVisitorAppeared(visitor))
        }

        if !state.fish[fi].isLegendary,
           state.fish[fi].tasksCompleted >= 50,
           state.fish[fi].tasksFailed * 10 < state.fish[fi].tasksCompleted {
            state.fish[fi].isLegendary = true
            events.append(.fishLegendaryChanged(fishID, true))
            AchievementCatalog.unlock(id: "legendary", in: &state, events: &events, now: now)
        }

        let stage = ReefStage.stage(forCompletedTasks: state.totalTasksCompleted)
        if stage != state.reefStage {
            state.reefStage = stage
            events.append(.reefStageChanged(stage))
            EngineSupport.log("The reef evolved (stage \(stage.rawValue))", in: &state, now: now)
        }

        EngineSupport.log(
            "\(key.provider.displayName) finished: \(summary ?? "a task")",
            in: &state, now: now
        )
        EngineSupport.setStatus(.celebrating, fishAt: fi, in: &state, events: &events)
    }

    private static func applyTaskFailed(
        _ key: SessionKey,
        reason: String?,
        to state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date
    ) {
        guard let fi = EngineSupport.boundFishIndex(forKey: key, in: state) else { return }
        let fishID = state.fish[fi].id
        state.fish[fi].tasksFailed += 1
        state.totalTasksFailed += 1
        if let pi = state.food.lastIndex(where: {
            $0.fish == fishID && ($0.state == .falling || $0.state == .available)
        }) {
            state.food[pi].state = .missed
            events.append(.foodMissed(id: state.food[pi].id))
        }
        EngineSupport.log(
            "\(key.provider.displayName) stumbled: \(reason ?? "task failed")",
            in: &state, now: now
        )
    }

    // MARK: - Handoffs

    private static func applyHandoff(
        _ key: SessionKey,
        subagentType: String,
        to state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date
    ) {
        guard let bi = EngineSupport.bindingIndex(forKey: key, in: state),
              let fi = EngineSupport.fishIndex(of: state.sessions[bi].fishID, in: state)
        else { return }
        let fishID = state.sessions[bi].fishID
        let pearl = Pearl(id: state.nextEntityID, fish: fishID, label: subagentType, createdAt: now)
        state.nextEntityID += 1
        state.pearls.append(pearl)
        state.sessions[bi].openPearlIDs.append(pearl.id)
        events.append(.pearlSpawned(pearl))
        state.fish[fi].lastActiveAt = now
        EngineSupport.setStatus(.handingOff, fishAt: fi, in: &state, events: &events)
    }

    private static func applyHandoffReturned(
        _ key: SessionKey,
        success: Bool,
        to state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date
    ) {
        guard let bi = EngineSupport.bindingIndex(forKey: key, in: state),
              !state.sessions[bi].openPearlIDs.isEmpty
        else { return }
        let pearlID = state.sessions[bi].openPearlIDs.removeFirst()
        guard let pi = state.pearls.firstIndex(where: { $0.id == pearlID }) else { return }
        let phase: Pearl.Phase = success ? .returned : .failed
        state.pearls[pi].phase = phase
        events.append(.pearlPhaseChanged(id: pearlID, phase: phase))
        EngineSupport.log(
            "Subagent \(state.pearls[pi].label) \(success ? "returned" : "failed")",
            in: &state, now: now
        )
    }

    // MARK: - Bugs

    private static func applyBugDetected(
        _ key: SessionKey,
        evidence: String,
        to state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date
    ) {
        let fi = EngineSupport.boundFishIndex(forKey: key, in: state)
        let label = EngineSupport.truncated(evidence)
        let severity = state.shark.isActive ? min(1, state.shark.severity + 0.25) : 0.5
        state.shark = SharkThreat(
            isActive: true,
            label: label,
            severity: severity,
            causeFish: fi.map { state.fish[$0].id },
            since: now
        )
        events.append(.sharkAppeared(label: label, severity: severity))
        if let fi {
            state.fish[fi].lastActiveAt = now
            EngineSupport.setStatus(.fixingBug, fishAt: fi, in: &state, events: &events)
        }
        EngineSupport.log("🦈 Bug: \(label)", in: &state, now: now)
    }

    private static func applyBugResolved(
        _ key: SessionKey,
        to state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date
    ) {
        guard state.shark.isActive else { return }
        let causeID = state.shark.causeFish
        state.shark = SharkThreat()
        events.append(.sharkLeft)
        let targetIndex = causeID.flatMap { EngineSupport.fishIndex(of: $0, in: state) }
            ?? EngineSupport.boundFishIndex(forKey: key, in: state)
        if let fi = targetIndex {
            // Stamp lastActiveAt so the celebration lasts the full revert window (see tick).
            state.fish[fi].lastActiveAt = now
            EngineSupport.setStatus(.celebrating, fishAt: fi, in: &state, events: &events)
        }
        AchievementCatalog.unlock(id: "shark-slayer", in: &state, events: &events, now: now)
        EngineSupport.log("Bug resolved — the shark swims away", in: &state, now: now)
    }

    // MARK: - Process-scan providers

    private static func applyProviderActivity(
        _ provider: AgentProvider,
        level: ActivityLevel,
        to state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date
    ) {
        // Session-backed providers are fully described by their transcript events.
        guard !state.sessions.contains(where: { $0.key.provider == provider }) else { return }
        let fishID = FishID.provider(provider)
        if level == .sleeping {
            guard let fi = EngineSupport.fishIndex(of: fishID, in: state) else { return }
            state.fish[fi].activityLevel = .sleeping
            EngineSupport.setStatus(.resting, fishAt: fi, in: &state, events: &events)
        } else {
            let status: AgentStatus = level == .walking ? .searching : .coding
            if let fi = EngineSupport.fishIndex(of: fishID, in: state) {
                state.fish[fi].activityLevel = level
                state.fish[fi].lastActiveAt = now
                EngineSupport.setStatus(status, fishAt: fi, in: &state, events: &events)
            } else {
                let fish = FishState(
                    id: fishID,
                    provider: provider,
                    displayName: provider.displayName,
                    isResident: false,
                    status: status,
                    activityLevel: level,
                    lastActiveAt: now,
                    createdAt: now
                )
                state.fish.append(fish)
                events.append(.fishAdded(fish))
            }
        }
    }
}

/// Time-based aging: thought expiry, fatigue, food timeout, reef/ambient/visitor/achievements.
enum EngineTicker {
    static func tick(
        _ state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date,
        rng: inout SplitMix64,
        calendar: Calendar
    ) {
        expireThoughts(&state, now: now)
        revertCelebrating(&state, events: &events, now: now)
        updateFatigue(&state, events: &events, now: now)
        ageFood(&state, events: &events, now: now)
        agePearls(&state, events: &events, now: now)
        resolveStaleShark(&state, events: &events, now: now)
        expireRareVisitor(&state, events: &events, now: now)
        updateAmbient(&state, events: &events, now: now, calendar: calendar)
        removeIdleProviderFish(&state, events: &events, now: now)
        AchievementCatalog.checkAll(in: &state, events: &events, now: now, calendar: calendar)
    }

    private static func expireThoughts(_ state: inout EcosystemState, now: Date) {
        for i in state.fish.indices where state.fish[i].thought.map({ $0.expiresAt < now }) == true {
            state.fish[i].thought = nil
        }
    }

    /// Celebrating fish revert to `.waiting` 4 s after `lastActiveAt` (both taskCompleted and
    /// bugResolved stamp it when they set `.celebrating`, so a celebration lasts ~4 s unless a
    /// newer status event overwrites it first).
    private static func revertCelebrating(
        _ state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date
    ) {
        for i in state.fish.indices
        where state.fish[i].status == .celebrating && now.timeIntervalSince(state.fish[i].lastActiveAt) >= 4 {
            EngineSupport.setStatus(.waiting, fishAt: i, in: &state, events: &events)
        }
    }

    private static func updateFatigue(
        _ state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date
    ) {
        for i in state.fish.indices {
            let old = state.fish[i].fatigue
            var new = old
            if state.fish[i].status.isActive {
                new = min(1, old + 0.0025)
            } else if state.fish[i].status == .resting || state.fish[i].status == .waiting {
                new = max(0, old - 0.01)
            }
            if new != old {
                state.fish[i].fatigue = new
                if EngineSupport.quantizedFatigue(new) != EngineSupport.quantizedFatigue(old) {
                    events.append(.fishFatigueChanged(state.fish[i].id, new))
                }
            }
            if state.fish[i].fatigue >= 0.95, state.fish[i].status.isActive {
                EngineSupport.setStatus(.resting, fishAt: i, in: &state, events: &events)
                state.fish[i].thought = ThoughtBubble(
                    message: "Taking a breather…",
                    expiresAt: now.addingTimeInterval(3)
                )
                events.append(.fishThought(state.fish[i].id, "Taking a breather…"))
            }
        }
    }

    private static func ageFood(
        _ state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date
    ) {
        var kept: [FoodPellet] = []
        kept.reserveCapacity(state.food.count)
        for var pellet in state.food {
            let age = now.timeIntervalSince(pellet.createdAt)
            switch pellet.state {
            case .falling:
                if age > 2.5 { pellet.state = .available }
            case .available:
                if age > 12 {
                    pellet.state = .missed
                    events.append(.foodMissed(id: pellet.id))
                }
            case .eaten, .missed:
                if age > 15 { continue }
            }
            kept.append(pellet)
        }
        state.food = kept
    }

    private static func agePearls(
        _ state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date
    ) {
        var kept: [Pearl] = []
        kept.reserveCapacity(state.pearls.count)
        for var pearl in state.pearls {
            let age = now.timeIntervalSince(pearl.createdAt)
            switch pearl.phase {
            case .outbound:
                if age > 2 {
                    pearl.phase = .working
                    events.append(.pearlPhaseChanged(id: pearl.id, phase: .working))
                }
            case .returned, .failed:
                if age > 5 { continue }
            case .working:
                break
            }
            kept.append(pearl)
        }
        state.pearls = kept
    }

    private static func resolveStaleShark(
        _ state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date
    ) {
        guard state.shark.isActive, let since = state.shark.since,
              now.timeIntervalSince(since) > 600 else { return }
        state.shark = SharkThreat()
        events.append(.sharkLeft)
    }

    private static func expireRareVisitor(
        _ state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date
    ) {
        guard let visitor = state.rareVisitor, visitor.until < now else { return }
        state.rareVisitor = nil
        events.append(.rareVisitorLeft)
    }

    private static func updateAmbient(
        _ state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date,
        calendar: Calendar
    ) {
        let phase = AmbientPhase.phase(forHour: calendar.component(.hour, from: now))
        guard phase != state.ambient.phase else { return }
        state.ambient.phase = phase
        events.append(.ambientChanged(state.ambient))
    }

    private static func removeIdleProviderFish(
        _ state: inout EcosystemState,
        events: inout [EcosystemEvent],
        now: Date
    ) {
        var removed: [FishID] = []
        state.fish.removeAll { fish in
            guard fish.id.isProviderScan,
                  fish.status == .resting || fish.activityLevel == .sleeping,
                  now.timeIntervalSince(fish.lastActiveAt) > 40
            else { return false }
            removed.append(fish.id)
            return true
        }
        for id in removed {
            events.append(.fishRemoved(id))
        }
    }
}
