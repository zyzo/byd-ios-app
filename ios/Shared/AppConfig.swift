import Foundation

/// Settings baked in at build time from ios/Config.xcconfig and Config.local.xcconfig.
enum AppConfig {
    static let serverURL: URL? = info("ServerURL").flatMap(URL.init(string:))
    static let serverToken = info("ServerToken") ?? ""
    static let displayName = info("CFBundleDisplayName") ?? "BYD Companion"
    static let bundleID = Bundle.main.bundleIdentifier ?? "byd-companion"
    /// Shared container of the app and its widget (entitlements + Info.plist "AppGroup").
    static let appGroup = info("AppGroup") ?? "group.byd-companion"
    /// Sample data instead of a real car (launch argument `-demo YES`). See Demo.swift.
    static let demo = UserDefaults.standard.bool(forKey: "demo")

    private static func info(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}
