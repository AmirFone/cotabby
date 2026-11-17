import Foundation
import Logging

/// The app's logger routes to OSLog and a file; the CLI only needs stderr, silenced unless
/// `--verbose` is passed.
nonisolated enum CotabbyLogger {
    static let suggestion = make("com.cotabby.suggestion")
    static let app = make("com.cotabby.app")
    static let runtime = make("com.cotabby.runtime")

    private static func make(_ label: String) -> Logger {
        var logger = Logger(label: label) { StreamLogHandler.standardError(label: $0) }
        logger.logLevel = CommandLine.arguments.contains("--verbose") ? .debug : .critical
        return logger
    }
}
