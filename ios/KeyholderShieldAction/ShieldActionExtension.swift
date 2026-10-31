import ManagedSettings
import Foundation

/// Handles the buttons on the shield. "Ask <name>" sends an unlock request
/// straight from the shield so the user never has to open the app to beg.
final class ShieldActionExtension: ShieldActionDelegate {

    override func handle(action: ShieldAction, for application: ApplicationToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        handle(action, completionHandler)
    }

    override func handle(action: ShieldAction, for webDomain: WebDomainToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        handle(action, completionHandler)
    }

    override func handle(action: ShieldAction, for category: ActivityCategoryToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        handle(action, completionHandler)
    }

    private func handle(_ action: ShieldAction, _ completion: @escaping (ShieldActionResponse) -> Void) {
        switch action {
        case .primaryButtonPressed:
            // Already asked recently: just close.
            if let at = SharedStore.pendingShieldRequestAt, Date().timeIntervalSince(at) < 3600 {
                completion(.close)
                return
            }
            SharedStore.pendingShieldRequestAt = Date()
            SharedStore.note("shield ask tapped")

            // Give the network a few seconds, then close regardless. The server
            // call is idempotent, and the app re-syncs on next open.
            let lock = NSLock()
            var finished = false
            let finish: () -> Void = {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                completion(.close)
            }
            let started = DeviceAPI.post(.requestUnlock, payload: [:]) { _ in finish() }
            if !started { finish(); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: finish)

        case .secondaryButtonPressed:
            completion(.close)

        @unknown default:
            completion(.close)
        }
    }
}
