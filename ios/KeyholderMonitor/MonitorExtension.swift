import DeviceActivity
import ManagedSettings
import FamilyControls
import Foundation

/// Runs without the app. Restores shields when an approved unlock expires,
/// lifts everything when Break Glass completes, and posts heartbeats.
final class MonitorExtension: DeviceActivityMonitor {

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        SharedStore.note("intervalDidStart \(activity.rawValue)")
        if activity == .heartbeat {
            postHeartbeat()
        }
        if activity == .allowance {
            // At midnight the allowance apps open again. Used minutes and the
            // used-up flag are stored with their day, so yesterday's no longer
            // count. (iOS may also call this when counting restarts mid-day;
            // nothing is reset here, so today's count survives.)
            reapplyShieldsIfLocked()
        }
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        if activity == .credit, let used = event.creditUsedSeconds {
            creditMark(used)
            return
        }
        guard activity == .allowance || activity == .allowanceToday else { return }
        if event == .allowanceDone {
            SharedStore.note("allowance used up")
            SharedStore.allowanceExhaustedDay = SharedStore.today
            SharedStore.setAllowanceUsed(SharedStore.allowanceMinutes)
            // During given time the allowance apps now count against it too.
            if SharedStore.isOpenForGivenTime, !MonitorScheduler.ensureCreditCounting() {
                SharedStore.note("credit recount failed")
            }
            reapplyShieldsIfLocked()
        } else if let minutes = event.allowanceUsedMinutes {
            SharedStore.setAllowanceUsed(max(SharedStore.allowanceUsedToday, minutes))
        }
    }

    /// Shields follow the allowance, except during time the keyholder gave.
    private func reapplyShieldsIfLocked() {
        guard SharedStore.blockActive else { return }
        ShieldController.applyStoredShieldsUnlessOpen()
    }

    /// Screen Time counted more of the given time. When it's used up the
    /// shields come back. The server hears every 5 minutes and at the end.
    private func creditMark(_ used: Int) {
        guard SharedStore.blockActive else { return }
        SharedStore.noteCreditUsed(used)
        if SharedStore.creditLeftSeconds <= 0 {
            SharedStore.note("given time used up")
            MonitorScheduler.stopCreditCounting()
            ShieldController.applyStoredShieldsUnlessOpen()
            reportCredit()
        } else if SharedStore.creditUsedSeconds - SharedStore.creditReportedSeconds >= 300 {
            reportCredit()
        }
    }

    private func reportCredit() {
        let used = SharedStore.creditUsedSeconds
        guard let blockID = SharedStore.blockID, used > SharedStore.creditReportedSeconds else { return }
        DeviceAPI.post(.creditUsed, payload: ["block_id": blockID, "used_seconds": used]) { ok in
            if ok { SharedStore.creditReportedSeconds = max(SharedStore.creditReportedSeconds, used) }
        }
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        SharedStore.note("intervalDidEnd \(activity.rawValue)")

        switch activity {
        case .unlockWindow:
            // A window being replaced or restarted is reported as ended too.
            // Only act when the given time is really over.
            if let until = SharedStore.unlockUntil, until.timeIntervalSinceNow > 60 {
                SharedStore.note("unlockWindow restart ignored")
                return
            }
            SharedStore.unlockUntil = nil
            SharedStore.pendingShieldRequestAt = nil
            if SharedStore.blockActive {
                ShieldController.applyStoredShieldsUnlessOpen()
            }
            postHeartbeat()

        case .credit:
            // Restarts and stops are reported as ends too. A stop clears the
            // end first; a restart moves it later.
            guard let end = SharedStore.scheduledEnd(for: .credit) else { return }
            if end.timeIntervalSinceNow > 60 {
                SharedStore.note("credit restart ignored")
                return
            }
            // The day's count is over. Count tomorrow's from zero if time is left.
            SharedStore.setScheduledEnd(nil, for: .credit)
            reportCredit()
            guard SharedStore.blockActive else { return }
            if !MonitorScheduler.ensureCreditCounting() {
                // Not counting means not open: better blocked than uncounted.
                ShieldController.applyStoredShieldsUnlessOpen()
            }

        case .breakGlass:
            // Same for Break Glass: never lift the block before the wait is over.
            guard let endsAt = SharedStore.breakGlassEndsAt, endsAt.timeIntervalSinceNow <= 60 else {
                SharedStore.note("breakGlass restart ignored")
                return
            }
            ShieldController.clearEverything()
            SharedStore.clearBlockState()
            DeviceAPI.post(.breakGlassDone)

        case .heartbeat:
            postHeartbeat()

        default:
            break
        }
    }

    /// A liveness ping. It deliberately says nothing about Screen Time access:
    /// in the background the extension can read "not authorized" while access
    /// is fine, which once ended a block at midnight. Only the app, after
    /// repeated checks, reports a revocation.
    private func postHeartbeat() {
        DeviceAPI.post(.heartbeat, payload: [
            "shielded": ShieldController.isShielding,
        ])
    }
}
