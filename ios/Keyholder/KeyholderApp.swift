import SwiftUI
import UIKit
import UserNotifications
import BackgroundTasks

@main
struct KeyholderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(state.screenTime)
                .task { await state.bootstrap() }
                .onOpenURL { url in state.handle(url: url) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await state.onForeground() }
                    } else if phase == .background {
                        PushRegistrar.scheduleBackgroundHeartbeat()
                    }
                }
        }
    }
}

// MARK: - Push, notification actions, background refresh

enum PushRegistrar {
    enum Action {
        static let approve15 = "APPROVE_15"
        static let approve60 = "APPROVE_60"
        static let deny = "DENY"
        static let approveApps = "APPROVE_APPS"
        static let denyApps = "DENY_APPS"
    }

    static let unlockRequestCategory = "UNLOCK_REQUEST"
    static let appChangeRequestCategory = "APP_CHANGE_REQUEST"
    static var heartbeatTaskID: String { "\(Bundle.main.bundleIdentifier ?? "com.keyholder.app").heartbeat" }

    static func configureCategories() {
        // authenticationRequired: nobody approves from someone else's lock screen.
        let approve15 = UNNotificationAction(identifier: Action.approve15, title: "Give 15 min",
                                             options: [.authenticationRequired])
        let approve60 = UNNotificationAction(identifier: Action.approve60, title: "Give 1 hour",
                                             options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: Action.deny, title: "Say no",
                                        options: [.authenticationRequired, .destructive])
        let category = UNNotificationCategory(identifier: unlockRequestCategory,
                                              actions: [approve15, approve60, deny],
                                              intentIdentifiers: [], options: [])

        let approveApps = UNNotificationAction(identifier: Action.approveApps, title: "Approve",
                                               options: [.authenticationRequired])
        let denyApps = UNNotificationAction(identifier: Action.denyApps, title: "Say no",
                                            options: [.authenticationRequired, .destructive])
        let appChange = UNNotificationCategory(identifier: appChangeRequestCategory,
                                               actions: [approveApps, denyApps],
                                               intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category, appChange])
    }

    static func requestPermissionAndRegister() async {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted {
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    static func scheduleBackgroundHeartbeat() {
        let request = BGAppRefreshTaskRequest(identifier: heartbeatTaskID)
        request.earliestBeginDate = Date().addingTimeInterval(4 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        PushRegistrar.configureCategories()

        BGTaskScheduler.shared.register(forTaskWithIdentifier: PushRegistrar.heartbeatTaskID, using: nil) { task in
            PushRegistrar.scheduleBackgroundHeartbeat()
            let work = Task { @MainActor in
                await AppState.shared.refresh()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in await AppState.shared.registerDevice(apnsToken: token) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Simulator or missing entitlement; the app still works through pull-to-refresh and realtime.
    }

    /// Silent/background delivery: keep the device in step with the server.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            await AppState.shared.refresh()
            completionHandler(.newData)
        }
    }

    /// Foreground delivery: show the banner and refresh.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in await AppState.shared.refresh() }
        completionHandler([.banner, .sound, .list])
    }

    /// Tap or quick action.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        Task { @MainActor in
            await AppState.shared.handleNotification(userInfo: userInfo, actionIdentifier: action)
            completionHandler()
        }
    }
}
