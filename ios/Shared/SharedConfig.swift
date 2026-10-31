import Foundation

/// Values injected from Config.xcconfig into each target's Info.plist, so the
/// app and all three extensions read the same configuration.
enum SharedConfig {
    static var appGroupID: String { info("APP_GROUP_ID") }
    static var supabaseAnonKey: String { info("SUPABASE_ANON_KEY") }

    static var supabaseURL: URL {
        guard let url = URL(string: info("SUPABASE_URL")), url.host != nil else {
            fatalError("SUPABASE_URL is not set in Config.xcconfig")
        }
        return url
    }

    /// Base URL for edge functions: https://<project>.supabase.co/functions/v1
    static var functionsURL: URL {
        supabaseURL.appendingPathComponent("functions").appendingPathComponent("v1")
    }

    private static func info(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
    }
}
