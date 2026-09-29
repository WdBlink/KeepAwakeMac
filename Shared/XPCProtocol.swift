import Foundation

@objc(KAMHelperProtocol)
protocol KAMHelperProtocol {
    func enableLidOpenKeepAwake(reply: @escaping (Bool, String?) -> Void)
    func disableLidOpenKeepAwake(reply: @escaping (Bool, String?) -> Void)
    func currentState(reply: @escaping (Bool, String?) -> Void)
    /// Mirrors the app's screen-awake switch so lid-close display sleep yields to it.
    func setDisplayHold(_ held: Bool, reply: @escaping (Bool, String?) -> Void)
}
