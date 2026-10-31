import ManagedSettings
import ManagedSettingsUI
import UIKit

/// The screen shown when a blocked app is opened: "Blocked. Ask Sarah."
final class ShieldConfigurationExtension: ShieldConfigurationDataSource {

    private func configuration() -> ShieldConfiguration {
        let holder = SharedStore.holderName ?? "your keyholder"

        // "Asked" for an hour after the shield button was used, so a tap-happy
        // user does not think nothing happened.
        let recentlyAsked = SharedStore.pendingShieldRequestAt.map { Date().timeIntervalSince($0) < 3600 } ?? false

        let subtitle: String
        let primary: String
        if let until = SharedStore.breakGlassEndsAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            subtitle = "Break Glass ends \(formatter.string(from: until)). Until then, ask \(holder)."
            primary = recentlyAsked ? "Asked" : "Ask \(holder)"
        } else if recentlyAsked {
            subtitle = "You asked \(holder). Waiting for an answer."
            primary = "Asked"
        } else {
            subtitle = "Ask \(holder) for time."
            primary = "Ask \(holder)"
        }

        return ShieldConfiguration(
            backgroundBlurStyle: .systemUltraThinMaterialDark,
            backgroundColor: UIColor.black.withAlphaComponent(0.55),
            icon: UIImage(systemName: "lock.fill"),
            title: ShieldConfiguration.Label(text: "Blocked", color: .white),
            subtitle: ShieldConfiguration.Label(text: subtitle, color: UIColor.white.withAlphaComponent(0.8)),
            primaryButtonLabel: ShieldConfiguration.Label(text: primary, color: .black),
            primaryButtonBackgroundColor: .white,
            secondaryButtonLabel: ShieldConfiguration.Label(text: "Not now", color: .white)
        )
    }

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        configuration()
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        configuration()
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        configuration()
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        configuration()
    }
}
