import Flutter

public final class BackupEngineMethodDelegate: NSObject, FlutterPlugin {
    public let operationIdentity: String
    private let registry: BackupEngineLifetimeRegistry

    public init(registry: BackupEngineLifetimeRegistry = .shared) {
        self.registry = registry
        operationIdentity = registry.register()
        super.init()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        BDPlugin.register(with: registrar)
    }

    public func fenceAdmissions() {
        registry.fence(operationIdentity)
    }

    public func engineWasDestroyed() {
        registry.didDestroy(operationIdentity)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "backupOperationIdentity":
            result(registry.isAccepting(operationIdentity) ? operationIdentity : nil)
        case "backupOperationState":
            guard let identity = call.arguments as? String else {
                result(BackupEngineLifetimeState.unknown.rawValue)
                return
            }
            result(registry.state(of: identity).rawValue)
        case "prepareManualUploadStaging":
            guard registry.isAccepting(operationIdentity), let root = call.arguments as? String else {
                result(FlutterError(code: "manual-staging-unavailable", message: nil, details: nil))
                return
            }
            do {
                result(try ManualUploadStagingExclusion.prepare(absoluteRoot: root))
            } catch {
                result(FlutterError(code: "manual-staging-unavailable", message: nil, details: nil))
            }
        case "enqueue", "enqueueAll":
            guard let admission = registry.beginAdmission(for: operationIdentity) else {
                result(FlutterError(code: "backup-engine-retired", message: nil, details: nil))
                return
            }
            BDPlugin.instance.handle(call, originIdentity: operationIdentity) { response in
                defer { admission.finish() }
                result(response)
            }
        default:
            BDPlugin.instance.handle(call, originIdentity: operationIdentity, result: result)
        }
    }
}
