import Foundation

@objc(KAMHelperProtocol)
protocol KAMHelperProtocol {
    func enableLidOpenKeepAwake(reply: @escaping (Bool, String?) -> Void)
    func disableLidOpenKeepAwake(reply: @escaping (Bool, String?) -> Void)
    func currentState(reply: @escaping (Bool, String?) -> Void)
    /// Mirrors the app's screen-awake switch so lid-close display sleep yields to it.
    func setDisplayHold(_ held: Bool, reply: @escaping (Bool, String?) -> Void)
    /// Which contract the running daemon implements. Added rather than folded
    /// into `currentState` so the three original signatures stay byte-identical.
    /// A daemon that predates it rejects the selector, which is exactly the
    /// signal the app needs: replace this helper rather than talk past it.
    func protocolInfo(reply: @escaping (Int) -> Void)
}
