import Foundation
import OSLog

enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.abyss.ios"

    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let conductor = Logger(subsystem: subsystem, category: "conductor")
    static let conversation = Logger(subsystem: subsystem, category: "conversation")
    static let tooling = Logger(subsystem: subsystem, category: "tooling")
    static let interaction = Logger(subsystem: subsystem, category: "interaction")
}
