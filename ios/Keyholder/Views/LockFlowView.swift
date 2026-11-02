import SwiftUI
import FamilyControls

/// Lock in four steps over the blurred scene: how to lock → which apps →
/// daily allowance → Break Glass wait, with a summary right above Lock.
struct LockFlowView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var screenTime: ScreenTimeController
    @Environment(\.dismiss) private var dismiss

    enum Step: Int, CaseIterable { case mode, apps, allowance, wait }

    @State private var step: Step = .mode
    @State private var coolingOffHours = 24
    @State private var choosingAllowanceApps = false

    private let coolingOffChoices = [12, 24, 48, 72]
    private let allowanceChoices = [0, 15, 30, 45, 60]

    private var holder: String { state.snapshot?.keyholder?.profile.displayName ?? "your keyholder" }

    var body: some View {
        ZStack {
            BlurredLandscape()
            if screenTime.isAuthorized {
                steps
            } else {
                needsPermission
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.25), value: step)
        .sheet(isPresented: $choosingAllowanceApps) { allowanceAppsSheet }
    }

    // MARK: Chrome

    private var steps: some View {
        VStack(spacing: 0) {
            topBar
            if step == .apps {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    appsPanel
                        .padding(.top, 22)
                }
                .padding(.horizontal, 20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        content
                            .padding(.top, 26)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
            bottomBar
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)
        }
    }

    private var topBar: some View {
        ZStack {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Capsule()
                        .fill(s == step ? AnyShapeStyle(LinearGradient(colors: [Theme.orangeLight, Theme.orangeMid],
                                                                         startPoint: .leading, endPoint: .trailing))
                              : AnyShapeStyle(Color.white.opacity(s.rawValue < step.rawValue ? 0.9 : 0.3)))
                        .frame(width: s == step ? 18 : 6, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")

            HStack {
                if step == .mode {
                    Button("Cancel") { dismiss() }
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.white60)
                        .frame(minHeight: 44)
                } else {
                    Button { back() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 19, weight: .semibold))
                            .frame(width: 44, height: 44, alignment: .leading)
                    }
                    .accessibilityLabel("Back")
                    .foregroundStyle(Theme.white60)
                }
                Spacer()
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 32, weight: .bold))
                .tracking(-0.8)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.system(size: 15))
                .foregroundStyle(Theme.white60)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 20)
    }

    private var title: String {
        switch step {
        case .mode: return "How do you want to lock?"
        case .apps: return screenTime.mode == .allExcept ? "What stays open" : "Apps to block"
        case .allowance: return "Daily allowance"
        case .wait: return "Break Glass wait"
        }
    }

    private var subtitle: String {
        switch step {
        case .mode:
            return "Apple keeps your choices on this phone. Keyholder never sees which apps they are."
        case .apps:
            return screenTime.mode == .allExcept
                ? "Pick the few apps you need, like Phone, Messages, Maps and your bank. Everything else is blocked."
                : "Pick the apps or categories to block, such as Social and Games."
        case .allowance:
            return "A few minutes a day on apps you choose. Once they're used up, those apps block until midnight."
        case .wait:
            return "If you ever need out without \(holder), Break Glass ends the block after a wait. Choose it now, while you mean it."
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .mode: modeContent
        case .apps: EmptyView()
        case .allowance: allowanceContent
        case .wait: waitContent
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        switch step {
        case .mode:
            Button(screenTime.mode == .allExcept ? "Choose what stays open" : "Choose apps to block") { next() }
                .buttonStyle(LockFlowButtonStyle())
        case .apps:
            VStack(spacing: 12) {
                Text(appsSummary)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.white60)
                    .multilineTextAlignment(.center)
                Button("Next") { next() }
                    .buttonStyle(LockFlowButtonStyle())
                    .disabled(!appsAreValid)
            }
        case .allowance:
            Button("Next") { next() }
                .buttonStyle(LockFlowButtonStyle())
                .disabled(!allowanceIsValid)
        case .wait:
            Button {
                Task {
                    await state.lock(coolingOffHours: coolingOffHours)
                    if state.snapshot?.block?.isActive == true { dismiss() }
                }
            } label: {
                Label("Lock", systemImage: "lock.fill")
            }
            .buttonStyle(LockFlowButtonStyle())
            .disabled(state.busy)
        }
    }

    private func next() {
        if step == .apps, screenTime.mode == .selected, AppChangePlan.isEmpty(screenTime.allowanceSelection) {
            // In "only the apps I pick" mode the allowance starts from the blocked apps.
            screenTime.allowanceSelection = screenTime.selection
        }
        if let n = Step(rawValue: step.rawValue + 1) { step = n }
    }

    private func back() {
        if let p = Step(rawValue: step.rawValue - 1) { step = p }
    }

    // MARK: 1. How to lock

    private var modeContent: some View {
        VStack(spacing: 12) {
            optionCard(.allExcept,
                       title: "Everything except essentials",
                       detail: "Every app is blocked except the few you keep open, like Phone, Messages, Maps and your bank. Apps you install later are blocked too.",
                       badge: "Recommended")
            optionCard(.selected,
                       title: "Only the apps I pick",
                       detail: "Choose the apps or categories to block, such as Social and Games.",
                       badge: nil)
        }
    }

    private func optionCard(_ mode: BlockMode, title: String, detail: String, badge: String?) -> some View {
        let selected = screenTime.mode == mode
        return Button {
            screenTime.mode = mode
        } label: {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().stroke(selected ? Theme.orangeMid : Color.white.opacity(0.5), lineWidth: 2)
                    if selected {
                        Circle().fill(LinearGradient(colors: [Theme.orangeLight, Theme.orangeMid],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 10, height: 10)
                    }
                }
                .frame(width: 22, height: 22)
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 17, weight: .semibold))
                        if let badge {
                            Text(badge)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.orangeLight)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Capsule().fill(Theme.orangeMid.opacity(0.22)))
                        }
                    }
                    Text(detail)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.white60)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.leading)
            .padding(18)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(selected ? Theme.orangeMid.opacity(0.14) : Theme.white08))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(selected ? Theme.orangeLight.opacity(0.75) : Theme.white15, lineWidth: selected ? 1.5 : 1))
            }
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: 2. Which apps

    private var appsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if screenTime.mode == .allExcept {
                    FamilyActivityPicker(selection: $screenTime.allowedSelection)
                } else {
                    FamilyActivityPicker(selection: $screenTime.selection)
                }
            }
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))

            Text("Apple's own picker. If a category looks empty, search for the app by name.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.white40)
                .padding(.horizontal, 4)
        }
    }

    private var appsSummary: String {
        if screenTime.mode == .allExcept {
            let n = screenTime.allowedCount
            return n == 0
                ? "Nothing kept open: every app will be blocked. Phone calls still work."
                : "\(n) \(n == 1 ? "app stays" : "apps stay") open. Everything else is blocked."
        }
        let c = screenTime.selectionCounts
        return c.apps + c.categories == 0
            ? "Pick at least one app or category."
            : "\(AppChange.describe(apps: c.apps, categories: c.categories)) will be blocked."
    }

    private var appsAreValid: Bool {
        if screenTime.mode == .allExcept { return true }
        let c = screenTime.selectionCounts
        return c.apps + c.categories > 0
    }

    // MARK: 3. Daily allowance

    private var allowanceIsValid: Bool {
        screenTime.allowanceMinutes == 0 || !AppChangePlan.isEmpty(screenTime.allowanceSelection)
    }

    private var allowanceAppsSummary: String {
        let c = AppChangePlan.counts(screenTime.allowanceSelection)
        return c.apps + c.categories == 0 ? "Choose…" : AppChange.describe(apps: c.apps, categories: c.categories)
    }

    private var allowanceContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: allowanceChoices.count), spacing: 8) {
                ForEach(allowanceChoices, id: \.self) { m in
                    choiceChip(m == 0 ? "Off" : UnlockDuration.format(minutes: m), selected: screenTime.allowanceMinutes == m) {
                        screenTime.allowanceMinutes = m
                    }
                }
            }

            if screenTime.allowanceMinutes > 0 {
                Button { choosingAllowanceApps = true } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Apps it covers").font(.system(size: 16, weight: .semibold))
                            Text("Opens Apple's app picker").font(.system(size: 13)).foregroundStyle(Theme.white40)
                        }
                        Spacer()
                        Text(allowanceAppsSummary).font(.system(size: 15)).foregroundStyle(Theme.white60)
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.white40)
                    }
                    .padding(.horizontal, 18)
                    .frame(minHeight: 60)
                    .glass(cornerRadius: 22)
                }
                .buttonStyle(PressScaleStyle())

                VStack(alignment: .leading, spacing: 12) {
                    TrackedLabel(text: "ON YOUR HOME SCREEN")
                    AllowanceBar(total: screenTime.allowanceMinutes, used: 0, available: true)
                    Text("You can turn it off while locked, or ask \(holder) for more.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.white40)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
            } else {
                Text("No allowance: your blocked apps stay blocked all day. \(holder) can give you one later.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.white60)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var allowanceAppsSheet: some View {
        NavigationStack {
            FamilyActivityPicker(
                headerText: "Pick the apps you can use for \(UnlockDuration.format(minutes: max(screenTime.allowanceMinutes, 15))) a day in total. If a category looks empty, search for the app by name.",
                footerText: nil,
                selection: $screenTime.allowanceSelection
            )
            .navigationTitle("Allowance apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { choosingAllowanceApps = false } }
            }
        }
    }

    // MARK: 4. Break Glass wait and summary

    private var waitContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: coolingOffChoices.count), spacing: 8) {
                ForEach(coolingOffChoices, id: \.self) { hours in
                    choiceChip(hours == 12 ? "12 h" : "\(hours / 24) day\(hours > 24 ? "s" : "")",
                               selected: coolingOffHours == hours) {
                        coolingOffHours = hours
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                rule("arrow.up", "You can make it longer later, never shorter.")
                rule("bell", "\(holder) is told the moment you break the glass.")
                rule("arrow.uturn.backward", "Cancel before it finishes and your streak survives.")
            }

            VStack(alignment: .leading, spacing: 0) {
                TrackedLabel(text: "YOU'RE LOCKING")
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                summaryRow("Blocking", blockingSummary)
                Divider().overlay(Color.white.opacity(0.10))
                summaryRow("Daily allowance", screenTime.allowanceMinutes > 0 && allowanceIsValid
                           ? "\(UnlockDuration.format(minutes: screenTime.allowanceMinutes)) on \(allowanceAppsSummary)"
                           : "Off")
                Divider().overlay(Color.white.opacity(0.10))
                summaryRow("Only unlocked by", holder)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 4)
            .glass(cornerRadius: 22)
        }
    }

    private var blockingSummary: String {
        if screenTime.mode == .allExcept {
            let n = screenTime.allowedCount
            return "Everything except \(n) \(n == 1 ? "app" : "apps")"
        }
        let c = screenTime.selectionCounts
        return AppChange.describe(apps: c.apps, categories: c.categories)
    }

    private func rule(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.orangeLight)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.white60)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 14)).foregroundStyle(Theme.white40)
            Spacer()
            Text(value).font(.system(size: 14)).multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 10)
    }

    // MARK: Pieces

    private func choiceChip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 15, weight: selected ? .bold : .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(selected ? Theme.ink : .white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.orangeGradient)
                    } else {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.white08))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.white15, lineWidth: 1))
                    }
                }
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var needsPermission: some View {
        VStack(spacing: 18) {
            Image(systemName: "hourglass").font(.system(size: 44, weight: .light))
            Text("Keyholder needs Screen Time access to block apps.")
                .font(Theme.sub)
                .multilineTextAlignment(.center)
            Button("Allow Screen Time access") {
                Task { await screenTime.requestAuthorization() }
            }
            .buttonStyle(GlassPillStyle())
            Button("Cancel") { dismiss() }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.white60)
        }
        .padding(32)
    }
}

/// The big orange button at the bottom of each Lock step.
struct LockFlowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Capsule().fill(Theme.orangeGradient))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
