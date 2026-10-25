import OSLog

enum Log {
    static let display = Logger(subsystem: "app.outbound.Outbound", category: "display")
    static let render = Logger(subsystem: "app.outbound.Outbound", category: "render")
    static let power = Logger(subsystem: "app.outbound.Outbound", category: "power")
}
