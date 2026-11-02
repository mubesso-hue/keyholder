import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var screenTime: ScreenTimeController
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var coolingOff = 24
    @State private var confirmSignOut = false
    @State private var renameTarget: Profile?

    private var block: Block? { state.snapshot?.block }
    private var isLocked: Bool { block?.isActive == true }

    var body: some View {
        NavigationStack {
            Form {
                Section("You") {
                    HStack {
                        TextField("Name", text: $name)
                        Button("Save") { Task { await state.updateDisplayName(name) } }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == state.snapshot?.me.displayName)
                    }
                }

                Section("Screen Time") {
                    HStack {
                        Text("Access")
                        Spacer()
                        Text(screenTime.isAuthorized ? "Allowed" : "Not allowed")
                            .foregroundStyle(screenTime.isAuthorized ? .green : .red)
                    }
                    if !screenTime.isAuthorized {
                        Button("Allow Screen Time access") { Task { await screenTime.requestAuthorization() } }
                    }
                }

                if let block, block.isActive {
                    Section {
                        Picker("Cooling-off", selection: $coolingOff) {
                            ForEach([12, 24, 48, 72].filter { $0 >= block.coolingOffHours }, id: \.self) { h in
                                Text("\(h) hours").tag(h)
                            }
                        }
                        Button("Lengthen") { Task { await state.lengthenCoolingOff(hours: coolingOff) } }
                            .disabled(coolingOff <= block.coolingOffHours || state.busy)
                    } header: {
                        Text("Break Glass wait")
                    } footer: {
                        Text("Currently \(block.coolingOffHours) hours. It can only get longer while locked.")
                    }
                }

                if let keyholder = state.snapshot?.keyholder {
                    Section {
                        HStack {
                            Text(keyholder.profile.displayName)
                            Spacer()
                            Button("Rename") { renameTarget = keyholder.profile }
                        }
                        Button("Remove keyholder", role: .destructive) {
                            Task { await state.endKey(keyholder.key) }
                        }
                        .disabled(isLocked || state.busy)
                    } header: {
                        Text("Your keyholder")
                    } footer: {
                        if isLocked { Text("You cannot remove your keyholder while locked.") }
                    }
                }

                if let held = state.snapshot?.held, !held.isEmpty {
                    Section("Keys you hold") {
                        ForEach(held) { item in
                            HStack {
                                Text(item.profile.displayName)
                                Spacer()
                                Button("Rename") { renameTarget = item.profile }
                                    .buttonStyle(.borderless)
                                Button("Stop holding", role: .destructive) {
                                    Task { await state.endKey(item.key) }
                                }
                                .buttonStyle(.borderless)
                                .disabled(item.block?.isActive == true || state.busy)
                            }
                        }
                    }
                }

                Section {
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                        .disabled(isLocked)
                } footer: {
                    if isLocked { Text("Signing out is disabled while locked.") }
                }

                Section("Diagnostics") {
                    LabeledContent("Device", value: SharedStore.deviceID.map { String($0.prefix(8)) } ?? "not registered")
                    LabeledContent("Shielding", value: ShieldController.isShielding ? "yes" : "no")
                    LabeledContent("Last extension event", value: SharedStore.lastExtensionEvent ?? "none")
                        .font(.footnote)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .renameAlert($renameTarget)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear {
                name = state.snapshot?.me.displayName ?? ""
                coolingOff = block?.coolingOffHours ?? 24
            }
            .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    Task {
                        await state.signOut()
                        dismiss()
                    }
                }
            }
        }
    }
}
