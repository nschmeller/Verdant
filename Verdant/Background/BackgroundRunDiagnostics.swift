import Foundation

/// Non-PHI breadcrumbs recording when the OS last actually granted each background window, so a user
/// can verify that on-power background compute is really happening (surfaced in Settings). iOS decides
/// when to grant these; the enhance window requires external power and typically fires while charging.
nonisolated enum BackgroundRunDiagnostics {
    private static let refreshKey = "verdant.diag.lastBackgroundRefreshAt"
    private static let enhanceKey = "verdant.diag.lastBackgroundEnhanceAt"

    static func stampRefresh(now: Date = .now) {
        UserDefaults.standard.set(now, forKey: refreshKey)
    }

    static func stampEnhance(now: Date = .now) {
        UserDefaults.standard.set(now, forKey: enhanceKey)
    }

    static var lastRefresh: Date? {
        UserDefaults.standard.object(forKey: refreshKey) as? Date
    }

    static var lastEnhance: Date? {
        UserDefaults.standard.object(forKey: enhanceKey) as? Date
    }
}
