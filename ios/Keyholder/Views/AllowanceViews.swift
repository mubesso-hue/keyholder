import SwiftUI
import FamilyControls

/// "ALLOWANCE TODAY · 10 of 30 min left" over a thin bar. The orange part is
/// what's left, so it shrinks as the minutes are used.
struct AllowanceBar: View {
    let total: Int
    let used: Int
    let available: Bool

    private var left: Int { max(0, total - min(used, total)) }
    private var fraction: CGFloat { total > 0 ? CGFloat(left) / CGFloat(total) : 0 }

    private var leftText: String {
        if total < 60 { return "\(left) of \(total) min left" }
        return "\(UnlockDuration.format(minutes: left)) of \(UnlockDuration.format(minutes: total)) left"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                TrackedLabel(text: "ALLOWANCE TODAY")
                Spacer()
                if available {
                    Text(leftText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.white60)
                        .monospacedDigit()
                } else {
                    Text("Used up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.orangeLight)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2))
                    if available {
                        Capsule()
                            .fill(LinearGradient(colors: [Theme.orangeLight, Theme.orangeMid],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(6, geo.size.width * fraction))
                    }
                }
            }
            .frame(height: 6)
            if !available {
                Text("Those apps open again at midnight.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.white60)
            }
        }
        .frame(maxWidth: 300)
        .legibleOnPhoto()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(available ? "Daily allowance: \(leftText)" : "Daily allowance used up until midnight")
    }
}

/// The locked person's allowance: what they have, ask for more, which apps it
/// covers, or turn it off.
struct AllowanceSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmOff = false

    private let choices = [15, 30, 45, 60, 90, 120]
    private var holder: String { state.snapshot?.keyholder?.profile.displayName ?? "your keyholder" }

    var body: some View {
        let minutes = SharedStore.allowanceMinutes
        let selection = SharedStore.allowanceSelection ?? FamilyActivitySelection(includeEntireCategory: true)
        let hasApps = !AppChangePlan.isEmpty(selection)
        let pending = state.snapshot?.myAllowanceRequest

        NavigationStack {
            List {
                Section {
                    if minutes > 0 {
                        LabeledContent("Each day", value: "\(UnlockDuration.format(minutes: minutes))")
                        if hasApps {
                            LabeledContent("Left today", value: SharedStore.allowanceAvailableToday
                                           ? "About \(UnlockDuration.format(minutes: max(0, minutes - SharedStore.allowanceUsedToday)))"
                                           : "Used up until midnight")
                        }
                    } else {
                        Text("You have no daily allowance. Everything in your block stays blocked all day.")
                            .foregroundStyle(.secondary)
                    }
                }

                if minutes > 0 {
                    Section {
                        NavigationLink {
                            AllowanceAppsPicker(initial: selection, minutes: minutes)
                        } label: {
                            LabeledContent("Apps it covers", value: hasApps ? appsSummary(selection) : "Choose…")
                        }
                    } footer: {
                        Text(hasApps
                             ? "Changing the apps keeps the time you've already used today."
                             : "\(holder) gave you this allowance. Choose which apps it covers to start using it.")
                    }
                }

                Section {
                    if let pending {
                        Text("You asked for \(UnlockDuration.format(minutes: pending.minutes)) a day. Waiting for \(holder)…")
                        Button("Withdraw request") { Task { await state.withdrawAllowanceRequest() } }
                            .disabled(state.busy)
                    } else {
                        ForEach(choices.filter { $0 > minutes }, id: \.self) { m in
                            Button("\(UnlockDuration.format(minutes: m)) a day") {
                                Task { await state.requestAllowance(minutes: m) }
                            }
                            .disabled(state.busy)
                        }
                    }
                } header: {
                    Text("Ask \(holder) for more")
                } footer: {
                    Text("\(holder) decides. Turning it down is always up to you.")
                }

                if minutes > 0 {
                    Section {
                        Button("Turn off allowance", role: .destructive) { confirmOff = true }
                            .disabled(state.busy)
                    } footer: {
                        Text("Those apps block right away. Only \(holder) can turn it back on.")
                    }
                }
            }
            .navigationTitle("Daily allowance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Turn off your daily allowance?", isPresented: $confirmOff, titleVisibility: .visible) {
                Button("Turn off", role: .destructive) { Task { await state.turnOffAllowance() } }
            } message: {
                Text("Those apps block right away. Only \(holder) can turn it back on.")
            }
        }
    }

    private func appsSummary(_ s: FamilyActivitySelection) -> String {
        let c = AppChangePlan.counts(s)
        return AppChange.describe(apps: c.apps, categories: c.categories)
    }
}

/// Apple's picker for the apps the allowance covers, with an explicit Save.
struct AllowanceAppsPicker: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FamilyActivitySelection
    let minutes: Int

    init(initial: FamilyActivitySelection, minutes: Int) {
        _draft = State(initialValue: initial)
        self.minutes = minutes
    }

    var body: some View {
        FamilyActivityPicker(
            headerText: "Pick the apps you can use for \(UnlockDuration.format(minutes: minutes)) a day in total. If a category looks empty, search for the app by name.",
            footerText: nil,
            selection: $draft
        )
        .navigationTitle("Allowance apps")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    state.setAllowanceApps(draft)
                    dismiss()
                }
                .disabled(AppChangePlan.isEmpty(draft))
            }
        }
    }
}
