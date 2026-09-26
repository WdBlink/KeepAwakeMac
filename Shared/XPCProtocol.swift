import Foundation

@objc(KAMHelperProtocol)
protocol KAMHelperProtocol {
    func enableLidOpenKeepAwake(reply: @escaping (Bool, String?) -> Void)
    func disableLidOpenKeepAwake(reply: @escaping (Bool, String?) -> Void)
    func currentState(reply: @escaping (Bool, String?) -> Void)
}
