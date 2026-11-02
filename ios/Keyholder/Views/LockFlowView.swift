import SwiftUI
import FamilyControls

/// Choose how to lock → pick apps → daily allowance → choose cooling-off → confirm.
struct LockFlowView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var screenTime: ScreenTimeController
    @Environment(\.dismiss) private var dismiss

    @State private var coolingOffHours = 24
    @State private var confirming = false

    private let coolingOffChoices = [12, 24, 48, 72]
    private let allowanceChoices = [0, 15, 30, 45, 60]

    var body: some View {
        NavigationStack {
            Group {
                if screenTime.isAuthorized {
                    modeChoice
                } else {
                    needsPermission
                }
            }
            .navigationTitle("Lock")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    // MARK: Step 1 — how to lock

    private var modeChoice: some View {
        List {
            Section {
                modeRow(.allExcept,
                        title: "Everything except essentials",
                        detail: "Every app is blocked except the few you keep open, like Phone, Messages, Maps and your bank. Apps you install later are blocked too.",
                        badge: "Recommended")
                modeRow(.selected,
                        title: "Only the apps I pick",
                        detail: "Choose the apps or categories to block, such as Social and Games.",
                        badge: nil)
            } header: {
                Text("How do you want to lock?")
            } footer: {
                Text("Apple keeps your choices on this phone. Keyholder never sees which apps they are.")
            }

            Section {
                NavigationLink {
                    picker
                } label: {
                    Text(screenTime.mode == .allExcept ? "Choose what stays open" : "Choose apps to block")
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func modeRow(_ mode: BlockMode, title: String, detail: String, badge: String?) -> some View {
        Button {
            screenTime.mode = mode
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: screenTime.mode == mode ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(screenTime.mode == mode ? Theme.orangeMid : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title).font(.headline).foregroundStyle(.primary)
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Theme.orangeMid.opacity(0.18)))
                                .foregroundStyle(Theme.orangeMid)
                        }
                    }
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: Step 2 — pick apps

    @ViewBuilder
    private var picker: some View {
        VStack(spacing: 0) {
            if screenTime.mode == .allExcept {
                FamilyActivityPicker(
                    headerText: "Pick the apps that stay open. Tap a category such as Finance or Navigation to keep all of its apps. Your choice is remembered for next time. If a category looks empty, search for the app by name.",
                    footerText: nil,
                    selection: $screenTime.allowedSelection
                )
            } else {
                FamilyActivityPicker(
                    headerText: "Pick the apps or categories to block. If a category looks empty, search for the app by name.",
                    footerText: nil,
                    selection: $screenTime.selection
                )
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text(pickerSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                NavigationLink {
                    allowanceStep
                } label: {
                    Text("Next").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!pickerIsValid)
            }
            .padding()
        }
        .navigationTitle(screenTime.mode == .allExcept ? "What stays open" : "Apps to block")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var pickerSummary: String {
        if screenTime.mode == .allExcept {
            let n = screenTime.allowedCount
            return n == 0
                ? "Nothing kept open: every app will be blocked. Phone calls still work."
                : "\(n) \(n == 1 ? "app stays" : "apps stay") open. Everything else is blocked."
        }
        let counts = screenTime.selectionCounts
        return "\(counts.apps) apps, \(counts.categories) categories selected"
    }

    private var pickerIsValid: Bool {
        if screenTime.mode == .allExcept { return true }
        let counts = screenTime.selectionCounts
        return counts.apps + counts.categories > 0
    }

    // MARK: Step 3 — daily allowance

    private var holderName: String { state.snapshot?.keyholder?.profile.displayName ?? "your keyholder" }

    private var allowanceIsValid: Bool {
        screenTime.allowanceMinutes == 0 || !AppChangePlan.isEmpty(screenTime.allowanceSelection)
    }

    private var allowanceAppsSummary: String {
        let c = AppChangePlan.counts(screenTime.allowanceSelection)
        return c.apps + c.categories == 0 ? "None yet" : AppChange.describe(apps: c.apps, categories: c.categories)
    }

    private var allowanceStep: some View {
        List {
            Section {
                Picker("Allowance", selection: $screenTime.allowanceMinutes) {
                    ForEach(allowanceChoices, id: \.self) { m in
                        Text(m == 0 ? "Off" : UnlockDuration.format(minutes: m)).tag(m)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Minutes a day before it fully blocks")
            } footer: {
                Text("Use the apps you choose for a few minutes a day. Once the time is used up, they block until midnight. You can turn it off while locked, but only \(holderName) can give you more.")
            }

            if screenTime.allowanceMinutes > 0 {
                Section {
                    NavigationLink {
                        FamilyActivityPicker(
                            headerText: "Pick the apps you can use for \(UnlockDuration.format(minutes: screenTime.allowanceMinutes)) a day in total. If a category looks empty, search for the app by name.",
                            footerText: nil,
                            selection: $screenTime.allowanceSelection
                        )
                        .navigationTitle("Allowance apps")
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        LabeledContent("Apps it covers", value: allowanceAppsSummary)
                    }
                } footer: {
                    if !allowanceIsValid { Text("Choose at least one app.") }
                }
            }

            Section {
                NavigationLink {
                    coolingOff
                } label: {
                    Text("Next").fontWeight(.semibold)
                }
                .disabled(!allowanceIsValid)
            }
        }
        .navigationTitle("Daily allowance")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // In "only the apps I pick" mode, start from the blocked apps.
            if screenTime.mode == .selected && AppChangePlan.isEmpty(screenTime.allowanceSelection) {
                screenTime.allowanceSelection = screenTime.selection
            }
        }
    }

    // MARK: Step 4 — cooling-off and confirm

    private var coolingOff: some View {
        let holder = state.snapshot?.keyholder?.profile.displayName ?? "your keyholder"
        return VStack(alignment: .leading, spacing: 20) {
            Text("If you ever need out without \(holder), Break Glass ends the block after a wait. Choose the wait now, while you mean it.")
                .font(.callout)

            Picker("Cooling-off", selection: $coolingOffHours) {
                ForEach(coolingOffChoices, id: \.self) { hours in
                    Text(hours == 12 ? "12 h" : "\(hours / 24) day\(hours > 24 ? "s" : "")").tag(hours)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 8) {
                Label("You can make it longer later, never shorter.", systemImage: "arrow.up")
                Label("\(holder) is told the moment you break the glass.", systemImage: "bell")
                Label("Cancel before it completes and your streak survives.", systemImage: "arrow.uturn.backward")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            Spacer()

            Button {
                confirming = true
            } label: {
                Label("Lock", systemImage: "lock.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(state.busy)
            .confirmationDialog("Lock now?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Lock", role: .destructive) {
                    Task {
                        await state.lock(coolingOffHours: coolingOffHours)
                        if state.snapshot?.block?.isActive == true { dismiss() }
                    }
                }
            } message: {
                Text("Only \(holder) can give you time back. Break Glass takes \(coolingOffHours) hours."
                     + (screenTime.allowanceMinutes > 0 && allowanceIsValid
                        ? " You get \(UnlockDuration.format(minutes: screenTime.allowanceMinutes)) a day on \(allowanceAppsSummary)."
                        : ""))
            }
        }
        .padding()
        .navigationTitle("Cooling-off")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var needsPermission: some View {
        VStack(spacing: 16) {
            Image(systemName: "hourglass").font(.largeTitle)
            Text("Keyholder needs Screen Time access to block apps.")
                .multilineTextAlignment(.center)
            Button("Allow Screen Time access") {
                Task { await screenTime.requestAuthorization() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
