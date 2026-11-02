import SwiftUI

/// Locked person asks for time. The keyholder decides the real duration.
struct RequestUnlockSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let holder = state.snapshot?.keyholder?.profile.displayName ?? "your keyholder"
        NavigationStack {
            List {
                Section {
                    ForEach(UnlockDuration.presets) { duration in
                        Button {
                            Task {
                                await state.requestUnlock(duration)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Text(duration.label)
                                Spacer()
                                Text("\(duration.minutes(now: state.serverNow)) min").foregroundStyle(.secondary)
                            }
                        }
                        .disabled(state.busy)
                    }
                    CustomDurationPicker(
                        actionTitle: { "Ask for \(UnlockDuration.format(minutes: $0))" },
                        disabled: state.busy
                    ) { minutes in
                        Task {
                            await state.requestUnlock(.custom(minutes))
                            dismiss()
                        }
                    }
                } header: {
                    Text("How long?")
                } footer: {
                    Text("This is a suggestion. \(holder) picks the actual duration, and the block comes back on its own when it ends.")
                }
            }
            .navigationTitle("Ask \(holder)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

/// Keyholder answers a request, or gives time unprompted.
struct DecideRequestSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmEnd = false

    let held: HeldKey

    private var request: UnlockRequest? { held.pendingRequest }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let request {
                        Text(request.requestedMinutes.map { "\(held.profile.displayName) is asking for \(UnlockDuration.format(minutes: $0))." }
                             ?? "\(held.profile.displayName) is asking for time.")
                    } else {
                        Text("\(held.profile.displayName) has not asked. You can still give time.")
                    }
                    Text("\(held.requestsThisWeek) requests this week.")
                        .foregroundStyle(.secondary)
                    if let endsAt = held.block?.breakGlassEndsAt {
                        Label {
                            Countdown(until: endsAt, offset: state.clockOffset, prefix: "Break Glass ends in ")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        }
                    }
                }

                if let change = held.pendingAppChange {
                    Section {
                        Text("\(held.profile.displayName) wants to \(change.change?.request ?? "change their blocked apps").")
                        Button("Approve") {
                            Task {
                                await state.decideAppChange(requestID: change.id, approve: true)
                                dismiss()
                            }
                        }
                        .disabled(state.busy)
                        Button("Say no") {
                            Task {
                                await state.decideAppChange(requestID: change.id, approve: false)
                                dismiss()
                            }
                        }
                        .disabled(state.busy)
                    } header: {
                        Text("App change")
                    } footer: {
                        Text("Apple keeps their apps private, so you see how many, not which. Blocking more never needs your OK.")
                    }
                }

                Section("Give time") {
                    ForEach(UnlockDuration.presets) { duration in
                        Button(duration.label) {
                            Task {
                                await act(.approvedTimed, duration: duration)
                                dismiss()
                            }
                        }
                        .disabled(state.busy)
                    }
                    CustomDurationPicker(
                        actionTitle: { "Give \(UnlockDuration.format(minutes: $0))" },
                        disabled: state.busy
                    ) { minutes in
                        Task {
                            await act(.approvedTimed, duration: .custom(minutes))
                            dismiss()
                        }
                    }
                }

                Section {
                    Button("End their block", role: .destructive) { confirmEnd = true }
                        .disabled(state.busy)
                    if request != nil {
                        Button("Say no") {
                            Task {
                                await act(.denied)
                                dismiss()
                            }
                        }
                        .disabled(state.busy)
                    }
                } footer: {
                    Text("Ending the block resets their streak. Their record is kept.")
                }
            }
            .navigationTitle(held.profile.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .confirmationDialog("End \(held.profile.displayName)'s block?", isPresented: $confirmEnd, titleVisibility: .visible) {
                Button("End block", role: .destructive) {
                    Task {
                        await act(.approvedEnd)
                        dismiss()
                    }
                }
            }
        }
    }

    private func act(_ decision: RequestDecision, duration: UnlockDuration? = nil) async {
        if let request {
            await state.decide(request, decision: decision, duration: duration)
        } else {
            await state.holderUnlock(held, decision: decision, duration: duration)
        }
    }
}

/// "Custom…" row that expands into hour and minute wheels, from 15 minutes to 24 hours.
struct CustomDurationPicker: View {
    let actionTitle: (Int) -> String
    var disabled = false
    let action: (Int) -> Void

    @State private var expanded: Bool

    init(actionTitle: @escaping (Int) -> String, disabled: Bool = false, startExpanded: Bool = false,
         action: @escaping (Int) -> Void) {
        self.actionTitle = actionTitle
        self.disabled = disabled
        self.action = action
        _expanded = State(initialValue: startExpanded)
    }
    @State private var hours = 0
    @State private var minutes = 45

    private let minuteSteps = Array(stride(from: 0, through: 55, by: 5))

    private var total: Int { hours * 60 + minutes }
    private var isValid: Bool {
        total >= UnlockDuration.minimumMinutes && total <= UnlockDuration.maximumMinutes
    }

    var body: some View {
        if expanded {
            VStack(spacing: 10) {
                HStack(spacing: 0) {
                    Picker("Hours", selection: $hours) {
                        ForEach(0..<25, id: \.self) { Text("\($0) h").tag($0) }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxWidth: .infinity, maxHeight: 130)
                    .clipped()

                    Picker("Minutes", selection: $minutes) {
                        ForEach(minuteSteps, id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxWidth: .infinity, maxHeight: 130)
                    .clipped()
                }
                .labelsHidden()

                Button {
                    action(total)
                } label: {
                    Text(isValid ? actionTitle(total) : (total < UnlockDuration.minimumMinutes ? "At least 15 minutes" : "At most 24 hours"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid || disabled)
            }
            .padding(.vertical, 4)
        } else {
            Button {
                withAnimation { expanded = true }
            } label: {
                HStack {
                    Text("Custom…")
                    Spacer()
                    Image(systemName: "chevron.down").foregroundStyle(.secondary)
                }
            }
            .disabled(disabled)
        }
    }
}
