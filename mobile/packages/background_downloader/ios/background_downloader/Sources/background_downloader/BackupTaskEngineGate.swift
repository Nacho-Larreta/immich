import Foundation

public final class BackupTaskNativeAdmission {
    private enum State { case reserved, started, finished }
    private let engineAdmission: BackupEngineAdmission?
    private let taskId: String
    private let metadata: String
    private let group: String
    private let lock = NSLock()
    private var state = State.reserved

    fileprivate init(_ admission: BackupEngineAdmission?, taskId: String, group: String, metadata: String) {
        engineAdmission = admission
        self.taskId = taskId
        self.group = group
        self.metadata = metadata
    }

    public func start(taskId: String, group: String, metadata: String) -> Bool {
        lock.withLock {
            guard state == .reserved, self.taskId == taskId, self.group == group, self.metadata == metadata else {
                return false
            }
            state = .started
            return true
        }
    }

    public func finish() {
        let needsFinish = lock.withLock {
            guard state != .finished else { return false }
            state = .finished
            return true
        }
        if needsFinish { engineAdmission?.finish() }
    }
}

public final class BackupTaskEngineGate {
    public static let shared = BackupTaskEngineGate(registry: .shared)

    private let registry: BackupEngineLifetimeRegistry

    public init(registry: BackupEngineLifetimeRegistry) {
        self.registry = registry
    }

    public func acceptsOrigin(_ identity: String?, group: String, metadata: String) -> Bool {
        guard requiresIdentity(group: group, metadata: metadata) else { return true }
        guard let identity, operationIdentity(metadata) == identity else { return false }
        return registry.isAccepting(identity)
    }

    public func begin(taskId: String = "", group: String, metadata: String) -> BackupTaskNativeAdmission? {
        guard requiresIdentity(group: group, metadata: metadata) else {
            return BackupTaskNativeAdmission(nil, taskId: taskId, group: group, metadata: metadata)
        }
        guard let identity = operationIdentity(metadata),
              let admission = registry.beginAdmission(for: identity) else { return nil }
        return BackupTaskNativeAdmission(admission, taskId: taskId, group: group, metadata: metadata)
    }

    private func requiresIdentity(group: String, metadata: String) -> Bool {
        if group == "backup_group" || group == "backup_live_photo_group" { return true }
        let values = metadataValues(metadata)
        return values?["runToken"] != nil || values?["bindingDigest"] != nil
    }

    private func operationIdentity(_ metadata: String) -> String? {
        metadataValues(metadata)?["operationIncarnation"] as? String
    }

    private func metadataValues(_ metadata: String) -> [String: Any]? {
        guard let data = metadata.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
