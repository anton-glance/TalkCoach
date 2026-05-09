import OSLog

extension Logger {
    // nonisolated so loggers are accessible from any isolation context (actors, Tasks, etc.).
    // Logger is Sendable; this is safe.
    private nonisolated static let subsystem = "com.talkcoach.app"

    nonisolated static let app = Logger(subsystem: subsystem, category: "app")
    nonisolated static let audio = Logger(subsystem: subsystem, category: "audio")
    nonisolated static let speech = Logger(subsystem: subsystem, category: "speech")
    nonisolated static let analyzer = Logger(subsystem: subsystem, category: "analyzer")
    nonisolated static let widget = Logger(subsystem: subsystem, category: "widget")
    nonisolated static let session = Logger(subsystem: subsystem, category: "session")
    nonisolated static let mic = Logger(subsystem: subsystem, category: "mic")
    nonisolated static let floatingPanel = Logger(subsystem: subsystem, category: "floatingPanel")
    nonisolated static let lang = Logger(subsystem: subsystem, category: "lang")
    nonisolated static let settings = Logger(subsystem: subsystem, category: "settings")
    nonisolated static let transcription = Logger(subsystem: subsystem, category: "transcription")
    nonisolated static let appleBackend = Logger(subsystem: subsystem, category: "appleBackend")
}
