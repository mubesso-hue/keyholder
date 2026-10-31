import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let snapshot = state.snapshot {
                        MyCardView(snapshot: snapshot)

                        if !snapshot.held.isEmpty {
                            Text("Keys you hold")
                                .font(.headline)
                                .padding(.top, 8)
                            ForEach(snapshot.held) { held in
                                HeldKeyCardView(held: held)
                            }
                        }

                        inviteButtons
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Keyholder")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { state.sheet = .settings } label: { Image(systemName: "gearshape") }
                }
            }
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
    }

    private var inviteButtons: some View {
        HStack(spacing: 12) {
            Button { state.sheet = .invite } label: {
                Label("Invite someone", systemImage: "person.badge.plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button { state.sheet = .accept(code: nil) } label: {
                Label("Enter a code", systemImage: "number").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(.top, 8)
    }
}

// MARK: - My card

struct MyCardView: View {
    @EnvironmentObject private var state: AppState
    let snapshot: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let block = snapshot.block, block.isActive {
                activeBlock(block)
            } else if let keyholder = snapshot.keyholder {
                readyToLock(keyholder)
            } else {
                noKeyholder
            }
        }
        .card()
    }

    // Locked --------------------------------------------------------------------

    @ViewBuilder
    private func activeBlock(_ block: Block) -> some View {
        let holderName = snapshot.keyholder?.profile.displayName ?? "your keyholder"

        HStack {
            statusLabel(block, holderName: holderName)
            Spacer()
            if !block.verified {
                Label("unverified", systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }

        StreakView(streak: snapshot.streak, offset: state.clockOffset)

        Text("\(block.appCount) apps, \(block.categoryCount) categories blocked. \(holderName) holds the key.")
            .font(.footnote)
            .foregroundStyle(.secondary)

        if let endsAt = block.breakGlassEndsAt {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Countdown(until: endsAt, offset: state.clockOffset, prefix: "Break Glass ends in ")
                        .font(.subheadline.weight(.semibold))
                }
                Text("Your streak resets when it completes. Cancel any time before \(endsAt.shortDateTime) to keep it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Cancel Break Glass") {
                    Task { await state.cancelBreakGlass() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.busy)
            }
            .padding(12)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }

        HStack(spacing: 12) {
            if let pending = snapshot.myPendingRequest {
                Label(pendingLabel(pending, holderName: holderName), systemImage: "hourglass")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                Button {
                    state.sheet = .request
                } label: {
                    Label("Ask \(holderName) for time", systemImage: "hand.raised").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.busy)
            }

            if block.breakGlassEndsAt == nil {
                Menu {
                    Button(role: .destructive) { state.sheet = .breakGlass } label: {
                        Label("Break Glass…", systemImage: "exclamationmark.triangle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title2)
                }
            }
        }
    }

    private func statusLabel(_ block: Block, holderName: String) -> some View {
        Group {
            if let until = block.unlockUntil, until > state.serverNow {
                Label("Unlocked until \(until.shortTime)", systemImage: "lock.open.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Locked", systemImage: "lock.fill")
            }
        }
        .font(.headline)
    }

    private func pendingLabel(_ request: UnlockRequest, holderName: String) -> String {
        if let minutes = request.requestedMinutes {
            return "Asked \(holderName) for \(minutes) min. Waiting…"
        }
        return "Asked \(holderName). Waiting…"
    }

    // Ready to lock ------------------------------------------------------------

    @ViewBuilder
    private func readyToLock(_ keyholder: Keyholder) -> some View {
        Label("\(keyholder.profile.displayName) holds your key", systemImage: "key.fill")
            .font(.headline)

        if snapshot.streak.isOnGrace, let graceUntil = snapshot.streak.graceUntil {
            VStack(alignment: .leading, spacing: 4) {
                StreakView(streak: snapshot.streak, offset: state.clockOffset, compact: true)
                Text("Streak paused. Lock again before \(graceUntil.shortDateTime) to keep it.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } else {
            Text("Record \(StreakState.format(snapshot.streak.bestSeconds))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }

        Button {
            state.sheet = .lock
        } label: {
            Label("Lock", systemImage: "lock.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)

        Text("Once locked, only \(keyholder.profile.displayName) can give you time.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    // No keyholder -------------------------------------------------------------

    @ViewBuilder
    private var noKeyholder: some View {
        Label("Nobody holds your key yet", systemImage: "key")
            .font(.headline)
        Text("Invite a friend to hold your key, or enter the code they sent you. You cannot lock until someone can unlock you.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        if snapshot.streak.bestSeconds > 0 {
            Text("Record \(StreakState.format(snapshot.streak.bestSeconds))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Someone whose key I hold

struct HeldKeyCardView: View {
    @EnvironmentObject private var state: AppState
    let held: HeldKey

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(held.profile.displayName).font(.headline)
                Spacer()
                status
            }

            if let block = held.block, block.isActive {
                if let streak = held.streak {
                    StreakView(streak: streak, offset: state.clockOffset, compact: true)
                }
                Text("\(block.appCount) apps, \(block.categoryCount) categories. \(held.requestsThisWeek) requests this week.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let endsAt = block.breakGlassEndsAt {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Countdown(until: endsAt, offset: state.clockOffset, prefix: "Broke the glass. Block ends in ")
                            .font(.subheadline.weight(.semibold))
                    }
                }

                if let request = held.pendingRequest {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(request.requestedMinutes.map { "Asking for \($0) min" } ?? "Asking for time")
                            .font(.subheadline.weight(.semibold))
                        HStack(spacing: 8) {
                            Button("15 min") { Task { await state.decide(request, decision: .approvedTimed, duration: .minutes(15)) } }
                            Button("1 hour") { Task { await state.decide(request, decision: .approvedTimed, duration: .minutes(60)) } }
                            Button("More…") { state.sheet = .decide(held) }
                            Spacer()
                            Button("No", role: .destructive) { Task { await state.decide(request, decision: .denied) } }
                        }
                        .buttonStyle(.bordered)
                        .disabled(state.busy)
                    }
                    .padding(12)
                    .background(Color.accentColor.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Button("Give time…") { state.sheet = .decide(held) }
                        .buttonStyle(.bordered)
                        .disabled(state.busy)
                }
            } else {
                Text("Not locked right now.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let streak = held.streak, streak.bestSeconds > 0 {
                    Text("Record \(StreakState.format(streak.bestSeconds))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .card()
    }

    @ViewBuilder
    private var status: some View {
        if let block = held.block, block.isActive {
            if let until = block.unlockUntil, until > state.serverNow {
                Label("Unlocked until \(until.shortTime)", systemImage: "lock.open.fill")
                    .font(.caption).foregroundStyle(.green)
            } else if !block.verified {
                Label("quiet", systemImage: "questionmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Label("Locked", systemImage: "lock.fill").font(.caption)
            }
        }
    }
}
