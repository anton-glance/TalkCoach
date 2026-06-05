@MainActor
protocol MicMonitorDelegate: AnyObject {
    func micActivated()
    func micDeactivated()
    func micDeviceChanged()
    var isSwitching: Bool { get }
}

@MainActor
extension MicMonitorDelegate {
    func micDeviceChanged() {}
    var isSwitching: Bool { false }
}
