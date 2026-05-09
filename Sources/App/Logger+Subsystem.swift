import OSLog

extension Logger {
    private static let subsystem = "com.talkcoach.app"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let speech = Logger(subsystem: subsystem, category: "speech")
    static let analyzer = Logger(subsystem: subsystem, category: "analyzer")
    static let widget = Logger(subsystem: subsystem, category: "widget")
    static let session = Logger(subsystem: subsystem, category: "session")
    static let mic = Logger(subsystem: subsystem, category: "mic")
    static let floatingPanel = Logger(subsystem: subsystem, category: "floatingPanel")
    static let lang = Logger(subsystem: subsystem, category: "lang")
    static let settings = Logger(subsystem: subsystem, category: "settings")
}
