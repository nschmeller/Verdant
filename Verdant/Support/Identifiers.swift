/// The single source of truth for app-wide identifiers. Avoids scattering the bundle id string
/// across loggers and background-task registration.
///
/// Note: the two background-task ids are *also* declared in `Info.plist`
/// (`BGTaskSchedulerPermittedIdentifiers`) — that list can't reference Swift, so keep the two in
/// sync if you change them here.
nonisolated enum Identifiers {
    static let bundle = "com.nschmeller.Verdant"
    static let loggerSubsystem = bundle
    static let refreshTask = "\(bundle).refresh"
    static let enhanceTask = "\(bundle).enhance"
}
