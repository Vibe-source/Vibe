import UIKit
import UserNotifications
import OSLog

private let appDelegateUITraceLogger = Logger(
  subsystem: "com.mohammadshayani.vibe.native",
  category: "UITrace"
)

private func appDelegateUITrace(_ message: String) {
  appDelegateUITraceLogger.notice("\(message, privacy: .public)")
  NSLog("[VibeUITrace] %@", message)
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  var window: UIWindow?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    appDelegateUITrace("AppDelegate didFinishLaunching")
    // Giphy SDK key for native GIF panel (Info.plist / env GIPHY_API_KEY).
    ChatGifPanelConfig.shared.reloadFromEnvironment()
    // Packet mesh is now opt-in (default direct). Downgrade any legacy
    // packet_mesh session to direct before the UI binds to the config so large
    // media sends (music/video/files) no longer fail immediately on mesh.
    ChatEngineStore.shared.migrateLegacyPacketMeshToDirectIfNeeded()
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = AppRootControllerFactory.makeInitialController()
    AppAppearanceController.applyStoredPreference(to: window)
    window.makeKeyAndVisible()

    self.window = window
    configureCallNotifications()
    VibeNativeCallManager.shared.start()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleDidReceiveMemoryWarning),
      name: UIApplication.didReceiveMemoryWarningNotification,
      object: nil
    )
    return true
  }

  func applicationDidBecomeActive(_ application: UIApplication) {
    appDelegateUITrace("AppDelegate didBecomeActive")
    // Resume the main-thread stall watchdog and reset its baseline so the time the
    // process spent suspended in the background is NOT counted as a stall.
    AppUIStallWatchdog.shared.setActive(true, context: "foreground")
  }

  func applicationWillResignActive(_ application: UIApplication) {
    appDelegateUITrace("AppDelegate willResignActive")
  }

  func applicationDidEnterBackground(_ application: UIApplication) {
    appDelegateUITrace("AppDelegate didEnterBackground")
    // Pause the watchdog: once iOS suspends the process the main-beat timer can't
    // tick, so on resume the elapsed wall-clock reads as a bogus ~20s "hang"
    // (cpu=0, run=waiting). Pausing here kills that false positive.
    AppUIStallWatchdog.shared.setActive(false, context: "background")
  }

  func applicationWillEnterForeground(_ application: UIApplication) {
    appDelegateUITrace("AppDelegate willEnterForeground")
  }

  func applicationWillTerminate(_ application: UIApplication) {
    appDelegateUITrace("AppDelegate willTerminate")
  }

  func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    // Every vibe:// link goes through one router: room-link (channel invites), u/handle
    // (@username share links), and chat (chatId/friendId). It decides what it can open
    // and ignores the rest, so new link shapes don't need a change here.
    guard url.scheme?.lowercased() == "vibe" else { return false }
    guard let target = VibeRoomLinkRouter.target(from: url) else { return false }
    Task { @MainActor in
      VibeRoomLinkRouter.shared.handle(target: target)
    }
    return true
  }

  func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
      let url = userActivity.webpageURL
    else { return false }
    Task { @MainActor in
      VibeRoomLinkRouter.shared.handle(url: url)
    }
    return true
  }

  @objc private func handleDidReceiveMemoryWarning() {
    appDelegateUITrace("AppDelegate didReceiveMemoryWarning")
    ChatWallpaperMaskStore.purge()
    ChatAvatarImageStore.purge()
    chatMediaImageCachePurgeForMemoryWarning()
  }

  func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    let handled = VibeNativeCallManager.shared.handleRemoteNotification(
      userInfo: userInfo,
      preferSystemUI: application.applicationState != .active
    )
    completionHandler(handled ? .newData : .noData)
  }

  private func configureCallNotifications() {
    let accept = UNNotificationAction(
      identifier: VibeNativeCallManager.foregroundCallAcceptAction,
      title: "Accept",
      options: [.foreground]
    )
    let decline = UNNotificationAction(
      identifier: VibeNativeCallManager.foregroundCallDeclineAction,
      title: "Decline",
      options: [.destructive]
    )
    let category = UNNotificationCategory(
      identifier: VibeNativeCallManager.foregroundCallCategoryIdentifier,
      actions: [accept, decline],
      intentIdentifiers: [],
      options: []
    )
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.setNotificationCategories([category])
    center.requestAuthorization(options: [.alert, .sound]) { granted, error in
      NSLog(
        "[VibeNativeCall] foreground notification auth granted=%@ error=%@",
        granted ? "true" : "false",
        error?.localizedDescription ?? "nil"
      )
      guard granted else { return }
      DispatchQueue.main.async {
        UIApplication.shared.registerForRemoteNotifications()
      }
    }
  }

  func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    VibeNativeCallManager.shared.setApnsDeviceToken(deviceToken)
  }

  func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    NSLog("[VibeNativeCall] APNs registration failed error=%@", error.localizedDescription)
    VibeNativeCallManager.shared.clearApnsDeviceToken()
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    guard notification.request.content.categoryIdentifier == VibeNativeCallManager.foregroundCallCategoryIdentifier else {
      completionHandler([])
      return
    }
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .sound])
    } else {
      completionHandler([.alert, .sound])
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    defer { completionHandler() }
    guard response.notification.request.content.categoryIdentifier == VibeNativeCallManager.foregroundCallCategoryIdentifier else {
      return
    }
    let payload = response.notification.request.content.userInfo.reduce(into: [String: Any]()) {
      $0[String(describing: $1.key)] = $1.value
    }
    switch response.actionIdentifier {
    case VibeNativeCallManager.foregroundCallAcceptAction:
      _ = VibeNativeCallEngine.shared.acceptIncoming(payload)
    case VibeNativeCallManager.foregroundCallDeclineAction:
      _ = VibeNativeCallEngine.shared.endCall(payload)
    default:
      _ = VibeNativeCallEngine.shared.handleSignal(payload)
    }
  }
}
