import native_video_player

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private static var isXCTestHost: Bool {
    ProcessInfo.processInfo.environment["IMMICH_XCTEST_HOST"] == "1"
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    URLSessionManager.initializeBlockedRequestContext()

    return finishLaunchingAfterRequestContextInitialization(
      application,
      launchOptions: launchOptions
    )
  }

  func finishLaunchingAfterRequestContextInitialization(
    _ application: UIApplication,
    launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    // Required for flutter_local_notification
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
    }

    SwiftNativeVideoPlayerPlugin.cookieStorage = URLSessionManager.cookieStorage
    URLSessionManager.patchBackgroundDownloader()
    BackgroundWorkerApiImpl.registerBackgroundWorkers()

    guard Self.shouldBootstrapFlutter(isXCTestHost: Self.isXCTestHost) else {
      return true
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  static func shouldBootstrapFlutter(isXCTestHost: Bool) -> Bool {
    !isXCTestHost
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    guard Self.shouldBootstrapFlutter(isXCTestHost: Self.isXCTestHost) else { return }
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    AppDelegate.registerPlugins(with: engineBridge.pluginRegistry, messenger: messenger)
  }

  public static func registerPlugins(
    with registry: FlutterPluginRegistry, messenger: FlutterBinaryMessenger
  ) {
    NativeSyncApiImpl.register(with: registry.registrar(forPlugin: NativeSyncApiImpl.name)!)
    let localImageFlutterApi = LocalImageFlutterApi(binaryMessenger: messenger)
    LocalImageApiSetup.setUp(
      binaryMessenger: messenger,
      api: LocalImageApiImpl(flutterApi: localImageFlutterApi)
    )
    RemoteImageApiSetup.setUp(binaryMessenger: messenger, api: RemoteImageApiImpl())
    let originalExportFlutterApi = OriginalExportFlutterApi(binaryMessenger: messenger)
    OriginalExportApiSetup.setUp(
      binaryMessenger: messenger,
      api: OriginalExportApiImpl(flutterApi: originalExportFlutterApi)
    )
    PerformanceApiSetup.setUp(binaryMessenger: messenger, api: PerformanceApiImpl())
    ProbeHttpApiSetup.setUp(binaryMessenger: messenger, api: ProbeHttpApiImpl())
    BackgroundWorkerFgHostApiSetup.setUp(binaryMessenger: messenger, api: BackgroundWorkerApiImpl())
    let connectivityFlutterApi = ConnectivityFlutterApi(binaryMessenger: messenger)
    ConnectivityApiSetup.setUp(
      binaryMessenger: messenger,
      api: ConnectivityApiImpl(flutterApi: connectivityFlutterApi)
    )
    NetworkApiSetup.setUp(binaryMessenger: messenger, api: NetworkApiImpl())
  }

  public static func cancelPlugins(with engine: FlutterEngine) {
    (engine.valuePublished(byPlugin: NativeSyncApiImpl.name) as? NativeSyncApiImpl)?
      .detachFromEngine()
  }
}
