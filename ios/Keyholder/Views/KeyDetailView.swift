import SwiftUI

/// Everything about one person whose key you hold, in one place: their streak,
/// anything waiting for your answer, giving time, their block, and the week.
struct KeyDetailView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let keyID: UUID

    @State private var history: KeyHistory?
    @State private var renameTarget: Profile?
    @State private var showCustom = false
    @State private var confirmEnd = false
    @State private var confirmStop = false

    private var held: HeldKey? { state.snapshot?.held.first { $0.id == keyID } }

    var body: some View {
        ZStack {
            LandscapeBackground()
            Theme.ink.opacity(0.35).ignoresSafeArea()

            if let held {
                ScrollView {
                    content(held)
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                        .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
                .refreshable { await state.refresh() }
            } else {
                VStack(spacing: 12) {
                    Text("This key has ended.")
                        .font(Theme.sub)
                    Button("Back to your keys") { dismiss() }
                        .buttonStyle(GlassPillStyle())
                }
                .foregroundStyle(.white)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if let held {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { renameTarget = held.profile } label: { Label("Rename…", systemImage: "pencil") }
                        Button(role: .destructive) { confirmStop = true } label: {
                            Label("Stop holding their key", systemImage: "xmark.circle")
                        }
                        .disabled(held.block?.isActive == true)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More options")
                }
            }
        }
        .tint(.white)
        .preferredColorScheme(.dark)
        .renameAlert($renameTarget)
        .sheet(isPresented: $showCustom) {
            if let held { customSheet(held) }
        }
        .task(id: state.snapshot?.serverTime) {
            if let held { history = await state.keyHistory(for: held) }
        }
    }

    // MARK: Layout

    @ViewBuilder
    private func content(_ held: HeldKey) -> some View {
        let block = held.block?.isActive == true ? held.block : nil
        VStack(alignment: .leading, spacing: 20) {
            header(held, block: block)
            streakCard(held, block: block)

            if let block, let endsAt = block.breakGlassEndsAt {
                breakGlassBanner(held, endsAt: endsAt)
            }
            if block != nil, let request = held.pendingRequest {
                requestCard(held, request: request)
            }
            if block != nil, let change = held.pendingAppChange {
                appChangeCard(held, change: change)
            }
            if let block, held.pendingRequest == nil {
                giveTimeCard(held, block: block)
            }
            if block == nil {
                Text("When \(held.profile.displayName) locks, you'll get a notification. Giving time and ending the block happen right here.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.white60)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glass(cornerRadius: 22)
            }
            if let block {
                blockSection(held, block: block)
            }
            weekSection(held)
            bottomAction(held, block: block)
        }
    }

    // MARK: Header and streak

    private func header(_ held: HeldKey, block: Block?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(held.profile.displayName)
                    .font(.system(size: 38, weight: .bold))
                    .tracking(-1)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                Button { renameTarget = held.profile } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.white40)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Rename \(held.profile.displayName)")
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                statusLine(held, block: block, now: context.date.addingTimeInterval(state.clockOffset))
            }
        }
        .foregroundStyle(.white)
        .legibleOnPhoto()
    }

    private func statusLine(_ held: HeldKey, block: Block?, now: Date) -> some View {
        let (text, dot): (String, AnyShapeStyle) = {
            guard let block else {
                if let ended = history?.lastBlock?.endedAt {
                    return ("Not locked · last block ended \(Self.dayTime(ended))", AnyShapeStyle(Theme.white40))
                }
                return ("Not locked", AnyShapeStyle(Theme.white40))
            }
            if let until = block.unlockUntil, until > now {
                return ("Unlocked until \(until.shortTime)", AnyShapeStyle(Theme.white60))
            }
            let checked = RelativeDateTimeFormatter().localizedString(for: block.lastHeartbeatAt, relativeTo: now)
            if !block.verified {
                return ("Locked · phone quiet, last checked in \(checked)", AnyShapeStyle(Theme.orangeLight))
            }
            return ("Locked since \(Self.since(block.startedAt)) · checked in \(checked)", AnyShapeStyle(Theme.orangeGradient))
        }()
        return HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.white60)
        }
    }

    private func streakCard(_ held: HeldKey, block: Block?) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date.addingTimeInterval(state.clockOffset)
            let current = held.streak?.currentSeconds(at: now) ?? 0
            let record = max(held.streak?.bestSeconds ?? 0, current)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    TrackedLabel(text: block != nil ? "CURRENT STREAK" : "RECORD")
                    Text(block != nil ? StreakState.clock(current) : StreakState.format(record))
                        .font(.system(size: 46, weight: .light))
                        .tracking(-1)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                Spacer()
                if block != nil {
                    stat("RECORD", StreakState.format(record))
                } else if let last = history?.lastBlock, let ended = last.endedAt {
                    stat("LAST BLOCK", StreakState.format(ended.timeIntervalSince(last.startedAt)))
                }
            }
            .foregroundStyle(.white)
            .padding(20)
            .glass(cornerRadius: 22)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            TrackedLabel(text: label)
            Text(value).font(.system(size: 20)).monospacedDigit()
        }
    }

    // MARK: Waiting for an answer

    private func breakGlassBanner(_ held: HeldKey, endsAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.breakRed)
                Text("\(held.profile.displayName) broke the glass").font(.system(size: 16, weight: .semibold))
            }
            Countdown(until: endsAt, offset: state.clockOffset, prefix: "Their block ends in ")
                .font(.system(size: 14))
                .foregroundStyle(Theme.white60)
            Text("You can still give time, or end the block now.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.white60)
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.breakRed.opacity(0.14)))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.breakRed.opacity(0.5), lineWidth: 1))
        }
    }

    private func requestCard(_ held: HeldKey, request: UnlockRequest) -> some View {
        let asked = request.requestedMinutes
        let main = asked ?? 30
        let others = [15, 30, 60].filter { $0 != main }.prefix(2)
        let nth = held.requestsThisWeek
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                TrackedLabel(text: "ASKING FOR TIME", color: Theme.orangeLight)
                Text(asked.map { UnlockDuration.format(minutes: $0) } ?? "Some time")
                    .font(.system(size: 26, weight: .semibold))
                Text("Sent \(RelativeDateTimeFormatter().localizedString(for: request.createdAt, relativeTo: state.serverNow))"
                     + (nth > 1 ? " · \(Self.ordinal(nth)) request this week" : ""))
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.white60)
            }
            Button("Give \(UnlockDuration.format(minutes: main))") { give(held, minutes: main) }
                .buttonStyle(OrangePillStyle())
            HStack(spacing: 8) {
                ForEach(Array(others), id: \.self) { m in
                    Button(UnlockDuration.format(minutes: m)) { give(held, minutes: m) }
                        .buttonStyle(GlassPillStyle(fullWidth: true))
                }
                Button("Custom…") { showCustom = true }
                    .buttonStyle(GlassPillStyle(fullWidth: true))
            }
            Button("Say no") { Task { await state.decide(request, decision: .denied) } }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.white60)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .foregroundStyle(.white)
        .disabled(state.busy)
        .attentionCard()
    }

    private func appChangeCard(_ held: HeldKey, change: UnlockRequest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                TrackedLabel(text: "APP CHANGE", color: Theme.orangeLight)
                Text("Wants to \(change.change?.request ?? "change their blocked apps")")
                    .font(.system(size: 22, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Apple keeps their apps private, so you see how many, not which.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.white60)
            }
            HStack(spacing: 8) {
                Button("Approve") { Task { await state.decideAppChange(requestID: change.id, approve: true) } }
                    .buttonStyle(OrangePillStyle())
                Button("Say no") { Task { await state.decideAppChange(requestID: change.id, approve: false) } }
                    .buttonStyle(GlassPillStyle(fullWidth: true))
            }
        }
        .foregroundStyle(.white)
        .disabled(state.busy)
        .attentionCard()
    }

    private func giveTimeCard(_ held: HeldKey, block: Block) -> some View {
        let unlocked = block.isTemporarilyUnlocked(at: state.serverNow)
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                TrackedLabel(text: "GIVE TIME")
                Text(unlocked
                     ? "Unlocked until \(block.unlockUntil?.shortTime ?? ""). Giving time now starts a new window from now."
                     : "\(held.profile.displayName) hasn't asked. You can still give time: their streak pauses while they're unlocked and carries on after.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.white60)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(UnlockDuration.presets) { duration in
                    Button(duration.label) { give(held, duration: duration) }
                        .buttonStyle(GlassPillStyle(fullWidth: true))
                }
            }
            Button("Custom…") { showCustom = true }
                .buttonStyle(GlassPillStyle(fullWidth: true))
        }
        .foregroundStyle(.white)
        .disabled(state.busy)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(cornerRadius: 22)
    }

    // MARK: Their block and the week

    private func blockSection(_ held: HeldKey, block: Block) -> some View {
        let mutual = state.snapshot?.keyholder?.profile.id == held.profile.id
        var rows: [(String, String)] = [("Blocking", blockingText(block))]
        if let m = block.allowanceMinutes, m > 0 {
            rows.append(("Daily allowance", "\(UnlockDuration.format(minutes: m)) a day"))
        }
        rows.append(("Break Glass wait", "\(block.coolingOffHours) hours"))
        rows.append(("Pact", mutual ? "Mutual: they hold your key too" : "You hold their key"))
        return section("THEIR BLOCK") {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.0).font(.system(size: 14)).foregroundStyle(Theme.white40)
                    Spacer()
                    Text(row.1).font(.system(size: 15)).multilineTextAlignment(.trailing)
                }
                .padding(.vertical, 14)
                if index < rows.count - 1 { Divider().overlay(Color.white.opacity(0.10)) }
            }
        }
    }

    private func weekSection(_ held: HeldKey) -> some View {
        section("THIS WEEK") {
            if let history {
                HStack(alignment: .top) {
                    weekStat("\(history.requests)", history.requests == 1 ? "request" : "requests")
                    weekStat("\(history.given)", "given")
                    weekStat(history.unlockedMinutes > 0 ? UnlockDuration.format(minutes: history.unlockedMinutes) : "0", "unlocked")
                }
                .padding(.vertical, 14)
                let items = Self.items(from: history, name: held.profile.displayName)
                if items.isEmpty {
                    Divider().overlay(Color.white.opacity(0.10))
                    Text("Nothing else this week.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.white60)
                        .padding(.vertical, 14)
                }
                ForEach(items) { item in
                    Divider().overlay(Color.white.opacity(0.10))
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.system(size: 15))
                            Text(Self.dayTime(item.date)).font(.system(size: 12)).foregroundStyle(Theme.white40)
                        }
                        Spacer()
                        Text(item.outcome)
                            .font(.system(size: 13, weight: item.waiting ? .semibold : .regular))
                            .foregroundStyle(item.waiting ? Theme.orangeLight : Theme.white60)
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(.vertical, 12)
                }
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.vertical, 20)
            }
        }
    }

    private func weekStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22))
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.white40)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TrackedLabel(text: title).padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 16)
                .glass(cornerRadius: 22)
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func bottomAction(_ held: HeldKey, block: Block?) -> some View {
        VStack(spacing: 8) {
            if block != nil {
                Button("End their block") { confirmEnd = true }
                    .buttonStyle(DangerOutlinePillStyle())
                    .disabled(state.busy)
                Text("Resets their streak. Their record is kept.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.white40)
            } else {
                Button("Stop holding their key") { confirmStop = true }
                    .buttonStyle(DangerOutlinePillStyle())
                    .disabled(state.busy)
                Text("They'll need a new keyholder before they can lock.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.white40)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .confirmationDialog("End \(held.profile.displayName)'s block?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End block", role: .destructive) { Task { await end(held) } }
        } message: {
            Text("Their streak resets. Their record is kept.")
        }
        .confirmationDialog("Stop holding \(held.profile.displayName)'s key?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop holding", role: .destructive) {
                Task {
                    await state.endKey(held.key)
                    dismiss()
                }
            }
        }
    }

    private func customSheet(_ held: HeldKey) -> some View {
        NavigationStack {
            Form {
                Section {
                    CustomDurationPicker(
                        actionTitle: { "Give \(UnlockDuration.format(minutes: $0))" },
                        disabled: state.busy,
                        startExpanded: true
                    ) { minutes in
                        showCustom = false
                        give(held, minutes: minutes)
                    }
                } footer: {
                    Text("From 15 minutes to 24 hours. The block comes back on its own.")
                }
            }
            .navigationTitle("Give \(held.profile.displayName) time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showCustom = false } }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: Actions

    private func give(_ held: HeldKey, minutes: Int) {
        give(held, duration: .custom(minutes))
    }

    /// Answers their request if there is one, otherwise gives time unasked.
    private func give(_ held: HeldKey, duration: UnlockDuration) {
        Task {
            if let request = held.pendingRequest {
                await state.decide(request, decision: .approvedTimed, duration: duration)
            } else {
                await state.holderUnlock(held, decision: .approvedTimed, duration: duration)
            }
        }
    }

    private func end(_ held: HeldKey) async {
        if let request = held.pendingRequest {
            await state.decide(request, decision: .approvedEnd)
        } else {
            await state.holderUnlock(held, decision: .approvedEnd)
        }
    }

    private func blockingText(_ block: Block) -> String {
        if block.isAllExcept {
            let n = block.allowedCount ?? 0
            return "Everything except \(n) \(n == 1 ? "app" : "apps")"
        }
        return AppChange.describe(apps: block.appCount, categories: block.categoryCount)
    }

    // MARK: History items

    struct Item: Identifiable {
        let id = UUID()
        let date: Date
        let title: String
        let outcome: String
        var waiting = false
    }

    static func items(from history: KeyHistory, name: String) -> [Item] {
        var items: [Item] = []
        for r in history.requestsList {
            let unasked = r.decidedAt != nil && r.decidedAt == r.createdAt
            if r.isAppChange {
                let title = (r.change?.request ?? "change apps").capitalizedFirst
                items.append(Item(date: r.createdAt, title: title, outcome: outcome(r), waiting: r.status == .pending))
            } else if unasked {
                let given = r.approvedMinutes.map { UnlockDuration.format(minutes: $0) }
                items.append(Item(date: r.createdAt,
                                  title: r.decision == .approvedEnd ? "You ended the block" : "You gave \(given ?? "time")",
                                  outcome: "Unasked"))
            } else {
                let asked = r.requestedMinutes.map { "Asked for \(UnlockDuration.format(minutes: $0))" } ?? "Asked for time"
                items.append(Item(date: r.createdAt, title: asked, outcome: outcome(r), waiting: r.status == .pending))
            }
        }
        for b in history.blocks {
            items.append(Item(date: b.startedAt, title: "Locked", outcome: lockedSummary(b)))
            if let ended = b.endedAt {
                items.append(Item(date: ended, title: "Block ended", outcome: endedReason(b.endedReason)))
            }
        }
        return Array(items.sorted { $0.date > $1.date }.prefix(8))
    }

    private static func outcome(_ r: UnlockRequest) -> String {
        switch r.status {
        case .pending: return "Waiting"
        case .denied: return "You said no"
        case .cancelled: return "Withdrawn"
        case .expired: return "Expired"
        case .approved:
            if r.isAppChange { return "Approved" }
            if r.decision == .approvedEnd { return "You ended the block" }
            return r.approvedMinutes.map { "Gave \(UnlockDuration.format(minutes: $0))" } ?? "Gave time"
        }
    }

    private static func lockedSummary(_ b: HistoryBlock) -> String {
        if b.mode == BlockMode.allExcept.rawValue {
            let n = b.allowedCount ?? 0
            return "Everything except \(n) \(n == 1 ? "app" : "apps")"
        }
        return AppChange.describe(apps: b.appCount ?? 0, categories: b.categoryCount ?? 0)
    }

    private static func endedReason(_ reason: BlockEndReason?) -> String {
        switch reason {
        case .holderEnded: return "You ended it"
        case .breakGlass: return "Break Glass"
        case .revoked: return "Screen Time turned off"
        case .orphaned: return "Pact ended"
        case nil: return ""
        }
    }

    // MARK: Dates

    /// "Today, 14:02", "Yesterday, 21:40", "Mon, 12:10".
    static func dayTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today, \(date.shortTime)" }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(date.shortTime)" }
        return "\(date.formatted(.dateTime.weekday(.abbreviated))), \(date.shortTime)"
    }

    /// "9:14" today, "Tue 9:14" this week, otherwise the date.
    static func since(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.shortTime }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 6 {
            return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(date.shortTime)"
        }
        return date.shortDateTime
    }

    static func ordinal(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .ordinal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

private extension String {
    /// "keep 2 more apps open" → "Keep 2 more apps open".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
