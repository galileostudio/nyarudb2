import Logging

/// Shared logger for internal engine events. The backend is configurable by
/// the application — by default logs go to `stdout` via `StreamLogHandler`.
///
/// Applications can supply a custom `LogHandler` factory before opening a
/// database, e.g. to funnel into `OSLog`, a file, or a telemetry service:
///
/// ```swift
/// LoggingSystem.bootstrap(MyHandler.init)
/// ```
public enum NyaruLogger {
  public private(set) static var log: Logging.Logger = {
    var l = Logging.Logger(label: "nyarudb2")
    l.logLevel = .info
    return l
  }()

  /// Override the log level for all NyaruDB loggers.
  /// Default: `.info`.
  public static var logLevel: Logging.Logger.Level {
    get { log.logLevel }
    set { log.logLevel = newValue }
  }

  /// Replaces the logger. Call this to attach a custom backend.
  public static func setLogger(_ logger: Logging.Logger) {
    log = logger
  }

  private static let companion = Logging.Logger(label: "nyarudb2")
  static func make(_ label: String) -> Logging.Logger {
    Logging.Logger(label: "nyarudb2.\(label)", factory: { _ in companion.handler })
  }
}
