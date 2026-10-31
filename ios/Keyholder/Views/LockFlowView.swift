import SwiftUI
import FamilyControls

/// Pick apps → choose cooling-off → confirm.
struct LockFlowView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var screenTime: ScreenTimeController
    @Environment(\.dismiss) private var dismiss

    @State private var coolingOffHours = 24
    @State private var confirming = false

    private let coolingOffChoices = [12, 24, 48, 72]

    var body: some View {
        NavigationStack {
            Group {
                if screenTime.isAuthorized {
                    picker
                } else {
                    needsPermission
                }
            }
            .navigationTitle("Choose apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private var picker: some View {
        VStack(spacing: 0) {
            FamilyActivityPicker(selection: $screenTime.selection)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                let counts = screenTime.selectionCounts
                Text("\(counts.apps) apps, \(counts.categories) categories selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                NavigationLink {
                    coolingOff
                } label: {
                    Text("Next").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(counts.apps + counts.categories == 0)
            }
            .padding()
        }
    }

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
                Text("Only \(holder) can give you time back. Break Glass takes \(coolingOffHours) hours.")
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
