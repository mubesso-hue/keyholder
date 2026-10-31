import SwiftUI
import FamilyControls

/// Asks for Screen Time access. Keyholder-only users can skip it.
struct PermissionView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var screenTime: ScreenTimeController
    @State private var requesting = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "hourglass")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Screen Time access")
                .font(.title.bold())
            VStack(alignment: .leading, spacing: 12) {
                Label("Keyholder uses Apple's Screen Time to block the apps you choose.", systemImage: "lock.shield")
                Label("Apple never shows us which apps you picked. We only see counts.", systemImage: "eye.slash")
                Label("Turning this off later in Settings ends your block and tells your keyholder.", systemImage: "bell")
            }
            .font(.callout)
            .padding(.horizontal)
            Spacer()

            Button {
                requesting = true
                Task {
                    await screenTime.requestAuthorization()
                    requesting = false
                }
            } label: {
                if requesting {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Allow Screen Time access").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("I'm only holding keys for now") {
                state.skippedPermission = true
            }
            .font(.footnote)

            if screenTime.status == .denied {
                Text("Access was denied. Enable it under Settings › Screen Time › Apps with Screen Time Access.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
    }
}
