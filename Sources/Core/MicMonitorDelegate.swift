@MainActor
protocol MicMonitorDelegate: AnyObject {
    func micActivated()
    func micDeactivated()
}
