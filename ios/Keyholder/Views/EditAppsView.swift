import SwiftUI
import FamilyControls

/// Change the blocked apps while locked. Blocking more takes effect right away;
/// opening anything up is sent to the keyholder, like asking for time.
struct EditAppsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    private let mode: BlockMode
    private let current: FamilyActivitySelection
    private let start: FamilyActivitySelection
    @State private var draft: FamilyActivitySelection

    init(mode: BlockMode, current: FamilyActivitySelection, start: FamilyActivitySelection) {
        self.mode = mode
        self.current = current
        self.start = start
        _draft = State(initialValue: start)
    }

    private var holder: String { state.snapshot?.keyholder?.profile.displayName ?? "your keyholder" }
    private var plan: AppChangePlan { AppChangePlan(mode: mode, current: current, draft: draft) }
    private var pending: PendingAppChange? { state.pendingAppChange }
    private var changed: Bool { !AppChangePlan.same(draft, start) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let request = state.snapshot?.myAppChange, pending != nil {
                    pendingBanner(request)
                }

                FamilyActivityPicker(headerText: headerText, footerText: nil, selection: $draft)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    summary
                    Button {
                        Task {
                            if await state.saveAppChange(draft) { dismiss() }
                        }
                    } label: {
                        Text(buttonTitle).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!changed || state.busy)
                }
                .padding()
            }
            .navigationTitle(mode == .allExcept ? "What stays open" : "Apps to block")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private var headerText: String {
        switch mode {
        case .allExcept:
            return "Removing an app from this list blocks it right away. Keeping more apps open needs \(holder)'s OK."
        case .selected:
            return "Blocking more apps works right away. Unblocking an app needs \(holder)'s OK."
        }
    }

    private func pendingBanner(_ request: UnlockRequest) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hourglass")
                .foregroundStyle(Theme.orangeMid)
            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting for \(holder)")
                    .font(.subheadline.weight(.semibold))
                Text("You asked to \(request.change?.request ?? "change your apps"). It's shown below as if approved.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Withdraw") {
                Task {
                    await state.withdrawAppChange()
                    dismiss()
                }
            }
            .font(.subheadline.weight(.semibold))
            .disabled(state.busy)
        }
        .padding()
        .background(Theme.orangeMid.opacity(0.12))
    }

    @ViewBuilder
    private var summary: some View {
        let plan = plan
        VStack(alignment: .leading, spacing: 6) {
            if !changed {
                Text("Tap apps above to change what's blocked.")
            } else {
                if plan.tightensAnything {
                    let c = AppChangePlan.counts(plan.closed)
                    Label("Blocked right away: \(AppChange.describe(apps: c.apps, categories: c.categories))",
                          systemImage: "lock.fill")
                }
                if plan.opensAnything {
                    let o = AppChangePlan.counts(plan.opened)
                    Label("Needs \(holder)'s OK: \(AppChange.describe(apps: o.apps, categories: o.categories))",
                          systemImage: "person.badge.key")
                } else if pending != nil {
                    Label("Your request to \(holder) will be withdrawn.", systemImage: "arrow.uturn.backward")
                }
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var buttonTitle: String {
        let plan = plan
        guard plan.opensAnything else { return "Save" }
        if let pending, AppChangePlan.same(pending.opened, plan.opened) { return "Save" }
        return pending == nil ? "Save and ask \(holder)" : "Save and ask \(holder) again"
    }
}
