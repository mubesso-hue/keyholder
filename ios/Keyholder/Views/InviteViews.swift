import SwiftUI

struct InviteView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var mode: InviteMode = .mutual
    @State private var code: String?

    private var hasKeyholder: Bool { state.snapshot?.keyholder != nil }

    var body: some View {
        NavigationStack {
            List {
                if let code {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(code)
                                .font(.system(size: 36, weight: .bold, design: .monospaced))
                                .textSelection(.enabled)
                            Text(mode.title).foregroundStyle(.secondary)
                        }
                        ShareLink(item: shareText(code)) {
                            Label("Share invite", systemImage: "square.and.arrow.up")
                        }
                    } footer: {
                        Text("Valid for 7 days. They open Keyholder, tap Enter a code, and paste it.")
                    }
                } else {
                    Section {
                        ForEach(InviteMode.allCases) { option in
                            Button {
                                mode = option
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.title).foregroundStyle(.primary)
                                        Text(option.detail).font(.footnote).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if option == mode { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                            }
                            .disabled(option != .iHoldYours && hasKeyholder)
                        }
                    } header: {
                        Text("What kind of key?")
                    } footer: {
                        if hasKeyholder {
                            Text("Someone already holds your key, so you can only offer to hold theirs.")
                        }
                    }

                    Section {
                        Button("Create invite") {
                            Task { code = await state.createInvite(mode: mode) }
                        }
                        .disabled(state.busy)
                    }
                }
            }
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onAppear { if hasKeyholder { mode = .iHoldYours } }
        }
    }

    private func shareText(_ code: String) -> String {
        let name = state.snapshot?.me.displayName ?? "A friend"
        switch mode {
        case .holdMine: return "\(name) wants you to hold their key on Keyholder. Code: \(code)  keyholder://invite/\(code)"
        case .iHoldYours: return "\(name) offered to hold your key on Keyholder. Code: \(code)  keyholder://invite/\(code)"
        case .mutual: return "\(name) wants a mutual pact on Keyholder. Code: \(code)  keyholder://invite/\(code)"
        }
    }
}

struct AcceptInviteView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var code: String
    @State private var preview: InvitePreview?

    init(initialCode: String) {
        _code = State(initialValue: initialCode)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Code", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.title3, design: .monospaced))
                        .onChange(of: code) { _, _ in preview = nil }
                    Button("Look up") {
                        Task { preview = await state.previewInvite(code: code) }
                    }
                    .disabled(code.trimmingCharacters(in: .whitespaces).count < 6 || state.busy)
                }

                if let preview {
                    Section {
                        Text("\(preview.inviterName): \(preview.mode.title)")
                            .font(.headline)
                        Text(describe(preview))
                            .foregroundStyle(.secondary)
                        if preview.usable {
                            Button("Accept") {
                                Task {
                                    if await state.acceptInvite(code: code) { dismiss() }
                                }
                            }
                            .disabled(state.busy)
                        } else {
                            Text("This invite cannot be used.").foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("Enter a code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task {
                if !code.isEmpty { preview = await state.previewInvite(code: code) }
            }
        }
    }

    private func describe(_ preview: InvitePreview) -> String {
        switch preview.mode {
        case .holdMine: return "You would hold \(preview.inviterName)'s key. You decide when they get time."
        case .iHoldYours: return "\(preview.inviterName) would hold your key. Only they can unlock you."
        case .mutual: return "You would hold each other's keys."
        }
    }
}
