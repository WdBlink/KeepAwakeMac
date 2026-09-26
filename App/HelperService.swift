import Foundation
import ServiceManagement

enum HelperService {
    static let service = SMAppService.daemon(plistName: "com.local.KeepAwakeMac.Helper.plist")

    static func prepare() throws {
        if service.status == .notRegistered || service.status == .notFound {
            do { try service.register() }
            catch {
                let failure = error as NSError
                if service.status == .requiresApproval ||
                    (failure.domain == "SMAppServiceErrorDomain" && failure.code == 1) {
                    throw ApprovalRequired()
                }
                throw error
            }
        }
        switch service.status {
        case .enabled: return
        case .requiresApproval:
            throw ApprovalRequired()
        default:
            throw ServiceError("The keep-awake service could not be registered. Run the installed app from Applications.")
        }
    }

    struct ApprovalRequired: LocalizedError {
        var errorDescription: String? {
            "Allow KeepAwakeMac in System Settings → General → Login Items & Extensions, then try again."
        }
    }

    struct ServiceError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
