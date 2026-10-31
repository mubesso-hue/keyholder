import SwiftUI

/// Main screen. Full-bleed landscape, one big Lock, everything else steps back.
struct HomeView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationStack {
            ZStack {
                LandscapeBackground()

                ScrollView {
                    VStack(spacing: 0) {
                        header

                        if let snapshot = state.snapshot {
                            HeroView(snapshot: snapshot, compact: !snapshot.held.isEmpty)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 18)

                            if !snapshot.held.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    TrackedLabel(text: "KEYS YOU HOLD")
                                    ForEach(snapshot.held) { held in
                                        HeldKeyRow(held: held)
                                    }
                                }
                                .padding(.top, 22)
                            }

                            footerLinks
                                .padding(.top, 28)
                                .padding(.bottom, 24)
                        } else {
                            ProgressView().tint(.white).padding(.top, 120)
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .scrollIndicators(.hidden)
            }
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await state.refresh() }
            .sheet(item: $state.sheet) { sheet in
                switch sheet {
                case .lock: LockFlowView()
                case .request: RequestUnlockSheet()
                case .breakGlass: BreakGlassView()
                case .invite: InviteView()
                case .settings: SettingsView()
                case .accept(let code): AcceptInviteView(initialCode: code ?? "")
                case .decide(let held): DecideRequestSheet(held: held)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text("Keyholder")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.white60)
            Spacer()
            Button { state.sheet = .settings } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 21, weight: .light))
                    .foregroundStyle(Theme.white60)
            }
            .accessibilityLabel("Settings")
        }
        .padding(.top, 10)
    }

    private var footerLinks: some View {
        HStack(spacing: 10) {
            Button("Invite someone") { state.sheet = .invite }
            Text("·")
            Button("Enter a code") { state.sheet = .accept(code: nil) }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Theme.white40)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Hero

struct HeroView: View {
    @EnvironmentObject private var state: AppState
    let snapshot: Snapshot
    var compact = false

    private var holderName: String { snapshot.keyholder?.profile.displayName ?? "your keyholder" }

    var body: some View {
        VStack(spacing: 0) {
            if let block = snapshot.block, block.isActive {
                locked(block)
            } else if snapshot.keyholder != nil {
                readyToLock
            } else {
                noKeyholder
            }
        }
        .multilineTextAlignment(.center)
    }

    // Locked ------------------------------------------------------------------

    @ViewBuilder
    private func locked(_ block: Block) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date.addingTimeInterval(state.clockOffset)
            let unlocked = block.isTemporarilyUnlocked(at: now)
            let paused = snapshot.streak.isPaused(at: now)
            let seconds = snapshot.streak.currentSeconds(at: now)

            VStack(spacing: 0) {
                headline(unlocked ? "Back in a moment." : "Phone down.\nLook up.")
                subline(unlocked ? "Unlocked until \(block.unlockUntil?.shortTime ?? "")." : "\(holderName) holds the key.")

                if !block.verified {
                    TrackedLabel(text: "UNVERIFIED · PHONE QUIET", color: Theme.orangeLight).padding(.top, 8)
                }

                SessionRing(seconds: seconds,
                            label: unlocked ? (paused ? "PAUSED" : "OPEN") : "LOCKED",
                            labelIsOrange: !unlocked,
                            dim: unlocked,
                            size: compact ? 160 : 200)
                    .padding(.top, compact ? 22 : (block.isBreakingGlass ? 22 : 34))
                    .padding(.bottom, compact ? 16 : (block.isBreakingGlass ? 14 : 26))

                if let endsAt = block.breakGlassEndsAt {
                    breakGlassPanel(endsAt: endsAt, now: now)
                        .padding(.top, 4)
                }

                actions(block)
                    .padding(.top, 18)

                RecordStat(seconds: max(snapshot.streak.bestSeconds, seconds))
                    .padding(.top, block.isBreakingGlass ? 18 : 26)
            }
        }
    }

    private func breakGlassPanel(endsAt: Date, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Break Glass ends in \(StreakState.format(max(0, endsAt.timeIntervalSince(now))))")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button("Cancel") { Task { await state.cancelBreakGlass() } }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.orangeLight)
                    .disabled(state.busy)
            }
            Text("Your streak resets when it completes. Cancel any time before \(endsAt.shortDateTime) to keep it.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.white60)
                .multilineTextAlignment(.leading)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass()
    }

    @ViewBuilder
    private func actions(_ block: Block) -> some View {
        HStack(spacing: 10) {
            if let pending = snapshot.myPendingRequest {
                Text(pending.requestedMinutes.map { "Asked \(holderName) for \($0) min. Waiting…" } ?? "Asked \(holderName). Waiting…")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.white60)
            } else {
                Button("Ask \(holderName) for time") { state.sheet = .request }
                    .buttonStyle(GlassPillStyle())
                    .disabled(state.busy)
            }

            if block.breakGlassEndsAt == nil {
                Menu {
                    Button(role: .destructive) { state.sheet = .breakGlass } label: {
                        Label("Break Glass…", systemImage: "exclamationmark.triangle")
                    }
                } label: {
                    Text("···")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background {
                            Circle().fill(.ultraThinMaterial)
                                .overlay(Circle().fill(Theme.white08))
                                .overlay(Circle().stroke(Theme.white15, lineWidth: 1))
                        }
                }
                .accessibilityLabel("More")
            }
        }
    }

    // Ready to lock -----------------------------------------------------------

    @ViewBuilder
    private var readyToLock: some View {
        headline("Be here now.")
        subline("\(holderName) holds your key.")

        LockButton(size: compact ? 132 : 176) { state.sheet = .lock }
            .padding(.top, compact ? 22 : 34)
            .padding(.bottom, compact ? 16 : 26)

        if snapshot.streak.isOnGrace, let graceUntil = snapshot.streak.graceUntil {
            helper("Streak paused at \(StreakState.format(snapshot.streak.currentSeconds())). Lock before \(graceUntil.shortDateTime) to keep it.", warn: true)
        } else {
            helper("Once locked, only \(holderName) can give you time.")
        }

        RecordStat(seconds: max(snapshot.streak.bestSeconds, snapshot.streak.currentSeconds()))
            .padding(.top, compact ? 16 : 26)
    }

    // No keyholder ------------------------------------------------------------

    @ViewBuilder
    private var noKeyholder: some View {
        headline("Nobody holds your key yet.")
        subline("Invite a friend, or enter their code.")

        LockButton(enabled: false, size: compact ? 132 : 176) {}
            .padding(.top, compact ? 22 : 34)
            .padding(.bottom, compact ? 16 : 26)

        if snapshot.streak.isOnGrace, let graceUntil = snapshot.streak.graceUntil {
            helper("Streak paused at \(StreakState.format(snapshot.streak.currentSeconds())). Find a keyholder and lock before \(graceUntil.shortDateTime) to keep it.", warn: true)
        } else {
            helper("You cannot lock until someone can unlock you.")
        }

        HStack(spacing: 10) {
            Button("Invite someone") { state.sheet = .invite }
            Button("Enter a code") { state.sheet = .accept(code: nil) }
        }
        .buttonStyle(GlassPillStyle())
        .padding(.top, 18)

        RecordStat(seconds: snapshot.streak.bestSeconds)
            .padding(.top, compact ? 16 : 26)
    }

    // Pieces -------------------------------------------------------------------

    private func headline(_ text: String) -> some View {
        Text(text)
            .font(Theme.headline(compact ? 36 : 46))
            .tracking(-1)
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            .legibleOnPhoto()
    }

    private func subline(_ text: String) -> some View {
        Text(text)
            .font(Theme.sub)
            .foregroundStyle(Theme.white60)
            .padding(.top, 12)
            .legibleOnPhoto()
    }

    private func helper(_ text: String, warn: Bool = false) -> some View {
        Text(text)
            .font(Theme.helper)
            .foregroundStyle(warn ? Theme.orangeLight : Theme.white60)
            .fixedSize(horizontal: false, vertical: true)
            .legibleOnPhoto()
    }
}

// MARK: - Someone whose key I hold

struct HeldKeyRow: View {
    @EnvironmentObject private var state: AppState
    let held: HeldKey

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date.addingTimeInterval(state.clockOffset)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(held.profile.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    status(now: now)
                }

                if let block = held.block, block.isActive {
                    let seconds = held.streak?.currentSeconds(at: now) ?? 0
                    HStack(alignment: .firstTextBaseline) {
                        Text(StreakState.clock(seconds))
                            .font(.system(size: 24, weight: .light))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                        Spacer()
                        TrackedLabel(text: "RECORD \(StreakState.format(max(held.streak?.bestSeconds ?? 0, seconds)))")
                    }
                    .padding(.top, 8)

                    Text(metaLine(block, now: now))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.white60)
                        .padding(.top, 4)

                    if let request = held.pendingRequest {
                        Text(request.requestedMinutes.map { "Asking for \($0) min" } ?? "Asking for time")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.top, 10)
                        HStack(spacing: 6) {
                            Button("15 min") { Task { await state.decide(request, decision: .approvedTimed, duration: .minutes(15)) } }
                            Button("1 hour") { Task { await state.decide(request, decision: .approvedTimed, duration: .minutes(60)) } }
                            Button("More…") { state.sheet = .decide(held) }
                            Button("No") { Task { await state.decide(request, decision: .denied) } }
                        }
                        .buttonStyle(GlassPillStyle(compact: true))
                        .disabled(state.busy)
                        .padding(.top, 10)
                    } else {
                        Button("Give time…") { state.sheet = .decide(held) }
                            .buttonStyle(GlassPillStyle(compact: true))
                            .disabled(state.busy)
                            .padding(.top, 10)
                    }
                } else if let streak = held.streak, streak.bestSeconds > 0 {
                    Text("Record \(StreakState.format(streak.bestSeconds))")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.white60)
                        .padding(.top, 4)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass()
        }
    }

    @ViewBuilder
    private func status(now: Date) -> some View {
        if let block = held.block, block.isActive {
            if block.isTemporarilyUnlocked(at: now), let until = block.unlockUntil {
                Text("Unlocked until \(until.shortTime)")
                    .font(.system(size: 12)).foregroundStyle(Theme.white60)
            } else {
                HStack(spacing: 6) {
                    Circle().fill(Theme.orangeGradient).frame(width: 6, height: 6)
                    Text(block.verified ? "Locked" : "Locked · quiet")
                        .font(.system(size: 12)).foregroundStyle(Theme.white60)
                }
            }
        } else {
            Text("Not locked").font(.system(size: 12)).foregroundStyle(Theme.white60)
        }
    }

    private func metaLine(_ block: Block, now: Date) -> String {
        var parts = ["\(block.appCount) apps, \(block.categoryCount) categories", "\(held.requestsThisWeek) requests this week"]
        if let endsAt = block.breakGlassEndsAt {
            parts.append("Broke the glass, ends in \(StreakState.format(max(0, endsAt.timeIntervalSince(now))))")
        }
        return parts.joined(separator: " · ")
    }
}
