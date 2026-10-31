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
                        Text(request.requestedMinutes.map { "\(held.profile.displayName) is asking for \($0) minutes." }
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
