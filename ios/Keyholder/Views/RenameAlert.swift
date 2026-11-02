import SwiftUI

/// Give someone you're tied to a name only you see.
struct RenameAlert: ViewModifier {
    @EnvironmentObject private var state: AppState
    @Binding var target: Profile?
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                   presenting: target) { profile in
                TextField(profile.realName ?? profile.displayName, text: $text)
                Button("Save") { Task { await state.rename(profile, to: text) } }
                if profile.hasNickname {
                    Button("Use their own name") { Task { await state.rename(profile, to: "") } }
                }
                Button("Cancel", role: .cancel) {}
            } message: { profile in
                Text("Only you see this name. Their own name is \(profile.realName ?? profile.displayName).")
            }
            .onChange(of: target) { _, newValue in
                text = newValue?.displayName ?? ""
            }
    }
}

extension View {
    func renameAlert(_ target: Binding<Profile?>) -> some View { modifier(RenameAlert(target: target)) }
}
