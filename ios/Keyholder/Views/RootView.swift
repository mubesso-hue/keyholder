import SwiftUI

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var screenTime: ScreenTimeController

    var body: some View {
        Group {
            switch state.phase {
            case .loading:
                ProgressView("Loading…")
            case .signedOut:
                SignInView()
            case .signedIn:
                if !screenTime.isAuthorized && !state.skippedPermission {
                    PermissionView()
                } else {
                    HomeView()
                }
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.errorMessage ?? "")
        }
    }
}

// MARK: - Small shared pieces

/// Live countdown such as "17h 22m".
struct Countdown: View {
    let until: Date
    let offset: TimeInterval
    var prefix: String = ""

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date.addingTimeInterval(offset)
            let remaining = max(0, until.timeIntervalSince(now))
            Text(prefix + StreakState.format(remaining))
                .monospacedDigit()
        }
    }
}

/// Live streak with the personal record under it.
struct StreakView: View {
    let streak: StreakState
    let offset: TimeInterval
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date.addingTimeInterval(offset)
            let current = streak.currentSeconds(at: now)
            let record = max(streak.bestSeconds, current)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(StreakState.format(current))
                        .font(compact ? .title2.weight(.bold) : .system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    if streak.isPaused(at: now) {
                        Label("paused", systemImage: "pause.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Record \(StreakState.format(record))")
                    .font(compact ? .caption : .subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

extension Date {
    var shortTime: String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: self)
    }

    var shortDateTime: String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: self)
    }
}
