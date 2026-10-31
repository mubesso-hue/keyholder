import Foundation

/// Calls the `device-event` edge function using the per-device secret.
/// Used by the extensions, which have no user session, and by the app as a fallback.
enum DeviceAPI {
    enum EventType: String {
        case heartbeat
        case requestUnlock = "request_unlock"
        case revoked
        case breakGlassDone = "break_glass_done"
    }

    @discardableResult
    static func post(_ type: EventType,
                     payload: [String: Any] = [:],
                     completion: ((Bool) -> Void)? = nil) -> Bool {
        guard let secret = SharedStore.deviceSecret, !secret.isEmpty else {
            completion?(false)
            return false
        }

        var request = URLRequest(url: SharedConfig.functionsURL.appendingPathComponent("device-event"))
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SharedConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(SharedConfig.supabaseAnonKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = ["secret": secret, "type": type.rawValue, "payload": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            completion?(false)
            return false
        }
        request.httpBody = data

        URLSession.shared.dataTask(with: request) { _, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            completion?(ok)
        }.resume()
        return true
    }

    /// Async variant for callers that want to wait for the result.
    static func send(_ type: EventType, payload: [String: Any] = [:]) async -> Bool {
        await withCheckedContinuation { continuation in
            let started = post(type, payload: payload) { ok in continuation.resume(returning: ok) }
            if !started { continuation.resume(returning: false) }
        }
    }
}
