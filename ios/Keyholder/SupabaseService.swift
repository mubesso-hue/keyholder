import Foundation
import Supabase

/// All network access. One method per RPC in supabase/migrations/0001_init.sql.
final class SupabaseService {
    static let shared = SupabaseService()

    let client: SupabaseClient

    private init() {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom(SupabaseDates.decode)

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601

        client = SupabaseClient(
            supabaseURL: SharedConfig.supabaseURL,
            supabaseKey: SharedConfig.supabaseAnonKey,
            options: SupabaseClientOptions(db: .init(encoder: encoder, decoder: decoder))
        )
    }

    // MARK: Auth

    var currentUserID: UUID? { client.auth.currentUser?.id }

    func signInWithApple(idToken: String, nonce: String) async throws {
        _ = try await client.auth.signInWithIdToken(
            credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)
        )
    }

    func signOut() async throws {
        try await client.auth.signOut()
    }

    // MARK: Snapshot

    func snapshot() async throws -> Snapshot {
        try await client.rpc("me_snapshot").execute().value
    }

    // MARK: Invites and keys

    func createInvite(mode: InviteMode) async throws -> String {
        try await client.rpc("create_invite", params: ["p_mode": mode.rawValue]).execute().value
    }

    func getInvite(code: String) async throws -> InvitePreview {
        try await client.rpc("get_invite", params: ["p_code": code]).execute().value
    }

    @discardableResult
    func acceptInvite(code: String) async throws -> [Key] {
        try await client.rpc("accept_invite", params: ["p_code": code]).execute().value
    }

    @discardableResult
    func endKey(id: UUID) async throws -> Key {
        try await client.rpc("end_key", params: ["p_key_id": id.uuidString]).execute().value
    }

    // MARK: Blocks

    private struct StartBlockParams: Encodable {
        let pCoolingOffHours: Int
        let pAppCount: Int
        let pCategoryCount: Int
    }

    private struct StartBlockAllExceptParams: Encodable {
        let pCoolingOffHours: Int
        let pAppCount: Int
        let pCategoryCount: Int
        let pMode: String
        let pAllowedCount: Int
    }

    /// Selected mode sends only the original three arguments, so it works against
    /// any server version. Everything-except mode needs migration 0004.
    func startBlock(coolingOffHours: Int, mode: BlockMode, appCount: Int, categoryCount: Int,
                    allowedCount: Int) async throws -> Block {
        switch mode {
        case .selected:
            return try await client.rpc("start_block", params: StartBlockParams(
                pCoolingOffHours: coolingOffHours, pAppCount: appCount, pCategoryCount: categoryCount
            )).execute().value
        case .allExcept:
            return try await client.rpc("start_block", params: StartBlockAllExceptParams(
                pCoolingOffHours: coolingOffHours, pAppCount: 0, pCategoryCount: 0,
                pMode: mode.rawValue, pAllowedCount: allowedCount
            )).execute().value
        }
    }

    func lengthenCoolingOff(hours: Int) async throws -> Block {
        try await client.rpc("lengthen_cooling_off", params: ["p_hours": hours]).execute().value
    }

    func startBreakGlass() async throws -> Block {
        try await client.rpc("start_break_glass").execute().value
    }

    func cancelBreakGlass() async throws -> Block {
        try await client.rpc("cancel_break_glass").execute().value
    }

    func completeBreakGlass() async throws -> Block {
        try await client.rpc("complete_break_glass").execute().value
    }

    func reportRevocation() async throws {
        try await client.rpc("report_revocation").execute()
    }

    private struct HeartbeatParams: Encodable {
        let pAuthorized: Bool
        let pShielded: Bool
    }

    func heartbeat(authorized: Bool, shielded: Bool) async throws {
        try await client.rpc("heartbeat", params: HeartbeatParams(pAuthorized: authorized, pShielded: shielded)).execute()
    }

    // MARK: Requests

    private struct RequestUnlockParams: Encodable {
        let pMinutes: Int?
    }

    func requestUnlock(minutes: Int?) async throws -> UnlockRequest {
        try await client.rpc("request_unlock", params: RequestUnlockParams(pMinutes: minutes)).execute().value
    }

    private struct DecideParams: Encodable {
        let pRequestId: String
        let pDecision: String
        let pMinutes: Int?
    }

    func decideUnlock(requestID: UUID, decision: RequestDecision, minutes: Int?) async throws -> UnlockRequest {
        try await client.rpc("decide_unlock", params: DecideParams(
            pRequestId: requestID.uuidString, pDecision: decision.rawValue, pMinutes: minutes
        )).execute().value
    }

    private struct HolderUnlockParams: Encodable {
        let pLockedId: String
        let pDecision: String
        let pMinutes: Int?
    }

    /// Keyholder gives time without being asked.
    func holderUnlock(lockedID: UUID, decision: RequestDecision, minutes: Int?) async throws -> UnlockRequest {
        try await client.rpc("holder_unlock", params: HolderUnlockParams(
            pLockedId: lockedID.uuidString, pDecision: decision.rawValue, pMinutes: minutes
        )).execute().value
    }

    // MARK: Changing apps while locked (migration 0005)

    private struct RequestAppChangeParams: Encodable {
        let pOpenedApps: Int
        let pOpenedCategories: Int
        let pAppCount: Int
        let pCategoryCount: Int
        let pAllowedCount: Int
    }

    /// Ask the keyholder to open apps up. The counts after the change describe the new block size.
    func requestAppChange(openedApps: Int, openedCategories: Int,
                          appCount: Int, categoryCount: Int, allowedCount: Int) async throws -> UnlockRequest {
        try await client.rpc("request_app_change", params: RequestAppChangeParams(
            pOpenedApps: openedApps, pOpenedCategories: openedCategories,
            pAppCount: appCount, pCategoryCount: categoryCount, pAllowedCount: allowedCount
        )).execute().value
    }

    private struct DecideAppChangeParams: Encodable {
        let pRequestId: String
        let pApprove: Bool
    }

    func decideAppChange(requestID: UUID, approve: Bool) async throws -> UnlockRequest {
        try await client.rpc("decide_app_change", params: DecideAppChangeParams(
            pRequestId: requestID.uuidString, pApprove: approve
        )).execute().value
    }

    func cancelAppChange() async throws {
        try await client.rpc("cancel_app_change").execute()
    }

    private struct UpdateBlockAppsParams: Encodable {
        let pAppCount: Int
        let pCategoryCount: Int
        let pAllowedCount: Int
    }

    /// Tell the server the block's new size after a change took effect on the phone.
    func updateBlockApps(appCount: Int, categoryCount: Int, allowedCount: Int) async throws -> Block {
        try await client.rpc("update_block_apps", params: UpdateBlockAppsParams(
            pAppCount: appCount, pCategoryCount: categoryCount, pAllowedCount: allowedCount
        )).execute().value
    }

    // MARK: Device and profile

    private struct RegisterDeviceParams: Encodable {
        let pApnsToken: String?
        let pDeviceId: String?
    }

    func registerDevice(apnsToken: String?, deviceID: String?) async throws -> Device {
        try await client.rpc("register_device", params: RegisterDeviceParams(
            pApnsToken: apnsToken, pDeviceId: deviceID
        )).execute().value
    }

    func updateDisplayName(_ name: String) async throws -> Profile {
        try await client.rpc("update_display_name", params: ["p_name": name]).execute().value
    }

    // MARK: Realtime

    /// Fires `onChange` whenever a row the user can see changes in the tables
    /// that drive the home screen. RLS scopes what is delivered.
    func subscribeToChanges(onChange: @escaping @Sendable () -> Void) async -> RealtimeChannelV2 {
        let channel = client.channel("home")
        let streams = ["unlock_requests", "blocks", "keys", "streaks"].map { table in
            channel.postgresChange(AnyAction.self, schema: "public", table: table)
        }
        for stream in streams {
            Task {
                for await _ in stream { onChange() }
            }
        }
        // Realtime is a nicety; pushes and pull-to-refresh still work if this fails.
        try? await channel.subscribe()
        return channel
    }
}

extension Error {
    /// Postgres `raise exception` messages come back wrapped; surface the useful part.
    var userMessage: String {
        if let pg = self as? PostgrestError {
            return pg.message
        }
        if isConnectionProblem {
            return "No connection. Check your signal and try again."
        }
        return localizedDescription
    }

    /// The request was cancelled, e.g. a pull-to-refresh that was let go.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        let ns = self as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    /// No signal, a dropped connection, a timeout, or a cancelled request:
    /// worth retrying quietly, not worth an alert.
    var isConnectionProblem: Bool {
        if self is CancellationError { return true }
        let ns = self as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        return connectionErrorCodes.contains(ns.code)
    }
}

private let connectionErrorCodes: Set<Int> = [
    NSURLErrorNetworkConnectionLost,
    NSURLErrorNotConnectedToInternet,
    NSURLErrorTimedOut,
    NSURLErrorCannotConnectToHost,
    NSURLErrorCannotFindHost,
    NSURLErrorDNSLookupFailed,
    NSURLErrorInternationalRoamingOff,
    NSURLErrorDataNotAllowed,
    NSURLErrorCallIsActive,
    NSURLErrorSecureConnectionFailed,
    NSURLErrorCancelled,
]
