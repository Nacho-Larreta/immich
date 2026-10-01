import Foundation

public enum BackupEngineLifetimeState: String {
    case alive
    case retired
    case unknown
}

public final class BackupEngineAdmission {
    private let finishAdmission: () -> Void

    fileprivate init(finish: @escaping () -> Void) {
        finishAdmission = finish
    }

    public func finish() {
        finishAdmission()
    }
}

public final class BackupEngineLifetimeRegistry {
    public static let shared = BackupEngineLifetimeRegistry()

    private struct Engine {
        var fenced = false
        var destroyed = false
        var admissions = Set<UUID>()
    }

    private let processGeneration = UUID()
    private let lock = NSLock()
    private var lastEngine: UInt64 = 0
    private var engines = [UInt64: Engine]()

    public init() {}

    public func register() -> String {
        lock.withLock {
            lastEngine += 1
            engines[lastEngine] = Engine()
            return "ios-engine-v1:\(processGeneration.uuidString):\(lastEngine)"
        }
    }

    public func state(of identity: String) -> BackupEngineLifetimeState {
        if isLegacyProcessIdentity(identity) { return .retired }
        guard let parsed = parse(identity) else { return .unknown }
        if parsed.process != processGeneration { return .retired }
        return lock.withLock {
            guard parsed.engine <= lastEngine else { return .unknown }
            guard let engine = engines[parsed.engine] else { return .retired }
            return engine.destroyed ? .unknown : .alive
        }
    }

    public func isAccepting(_ identity: String) -> Bool {
        guard let parsed = parse(identity), parsed.process == processGeneration else { return false }
        return lock.withLock {
            guard let engine = engines[parsed.engine] else { return false }
            return !engine.fenced && !engine.destroyed
        }
    }

    public func beginAdmission(for identity: String) -> BackupEngineAdmission? {
        guard let parsed = parse(identity), parsed.process == processGeneration else { return nil }
        return lock.withLock {
            guard var engine = engines[parsed.engine], !engine.fenced && !engine.destroyed else { return nil }
            let admission = UUID()
            engine.admissions.insert(admission)
            engines[parsed.engine] = engine
            return BackupEngineAdmission { [self] in
                finishAdmission(admission, engine: parsed.engine)
            }
        }
    }

    public func fence(_ identity: String) {
        guard let parsed = parse(identity), parsed.process == processGeneration else { return }
        lock.withLock {
            guard var engine = engines[parsed.engine] else { return }
            engine.fenced = true
            engines[parsed.engine] = engine
        }
    }

    public func didDestroy(_ identity: String) {
        guard let parsed = parse(identity), parsed.process == processGeneration else { return }
        lock.withLock {
            guard var engine = engines[parsed.engine], engine.fenced else { return }
            engine.destroyed = true
            storeOrRetire(engine, number: parsed.engine)
        }
    }

    private func finishAdmission(_ admission: UUID, engine number: UInt64) {
        lock.withLock {
            guard var engine = engines[number] else { return }
            engine.admissions.remove(admission)
            storeOrRetire(engine, number: number)
        }
    }

    private func storeOrRetire(_ engine: Engine, number: UInt64) {
        if engine.fenced && engine.destroyed && engine.admissions.isEmpty {
            engines.removeValue(forKey: number)
        } else {
            engines[number] = engine
        }
    }

    private func parse(_ identity: String) -> (process: UUID, engine: UInt64)? {
        let parts = identity.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "ios-engine-v1",
              let process = UUID(uuidString: String(parts[1])),
              let engine = UInt64(parts[2]), engine > 0 else { return nil }
        return (process, engine)
    }

    private func isLegacyProcessIdentity(_ identity: String) -> Bool {
        let parts = identity.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0] == "pid" && UInt64(parts[1]).map { $0 > 0 } == true
    }
}
