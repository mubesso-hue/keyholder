import SwiftUI

struct BreakGlassView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false

    var body: some View {
        let block = state.snapshot?.block
        let holder = state.snapshot?.keyholder?.profile.displayName ?? "your keyholder"
        let hours = block?.coolingOffHours ?? 24
        let endsAt = state.serverNow.addingTimeInterval(TimeInterval(hours) * 3600)

        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.red)
                    Text("Break Glass")
                        .font(.largeTitle.bold())
                }

                if let pendingEnd = block?.breakGlassEndsAt {
                    Countdown(until: pendingEnd, offset: state.clockOffset, prefix: "Ends in ")
                        .font(.title2.weight(.semibold))
                    Text("Already started. \(holder) knows. Cancel to keep your streak.")
                    Spacer()
                    Button("Cancel Break Glass") {
                        Task {
                            await state.cancelBreakGlass()
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(state.busy)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        row("clock", "Your block ends at \(endsAt.shortDateTime), in \(hours) hours.")
                        row("bell.fill", "\(holder) is told right now, and again when it completes.")
                        row("flame", "Your streak resets when it completes. Your record stays.")
                        row("arrow.uturn.backward", "Cancel any time before then and nothing is lost.")
                        row("hand.raised", "\(holder) can cut the wait short by unlocking you.")
                        if state.snapshot?.held.contains(where: { $0.profile.id == state.snapshot?.keyholder?.profile.id }) == true {
                            row("person.2", "You are in a mutual pact. Completing this also lifts \(holder)'s block.")
                        }
                    }
                    .font(.callout)

                    Spacer()

                    Button(role: .destructive) {
                        confirming = true
                    } label: {
                        Text("Break the glass").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                    .disabled(state.busy)
                    .confirmationDialog("Start the \(hours) hour wait?", isPresented: $confirming, titleVisibility: .visible) {
                        Button("Break the glass", role: .destructive) {
                            Task {
                                await state.startBreakGlass()
                                dismiss()
                            }
                        }
                    } message: {
                        Text("\(holder) will be notified immediately.")
                    }
                }
            }
            .padding(24)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }

    private func row(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 24)
            Text(text)
        }
    }
}
