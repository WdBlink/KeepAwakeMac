import Foundation

/// All helper calls complete with a reply, a connection error, or a timeout.
actor PrivilegedHelperClient {
    static let shared = PrivilegedHelperClient()

    private let makeConnection: () -> NSXPCConnection
    private let timeout: TimeInterval

    init(timeout: TimeInterval = AppConstants.helperRequestTimeout,
         makeConnection: @escaping () -> NSXPCConnection = {
             NSXPCConnection(machServiceName: AppConstants.helperMachServiceName,
                             options: .privileged)
         }) {
        self.timeout = timeout
        self.makeConnection = makeConnection
    }

    func enable() async throws -> Bool {
        try await request { proxy, reply in
            proxy.enableLidOpenKeepAwake(reply: reply)
        }
    }

    func disable() async throws -> Bool {
        try await request { proxy, reply in
            proxy.disableLidOpenKeepAwake(reply: reply)
        }
    }

    func isCurrentlyEnabled() async throws -> Bool {
        try await request { proxy, reply in
            proxy.currentState(reply: reply)
        }
    }

    /// Mirrors the screen-awake switch so the helper's lid-close display sleep
    /// yields to it.
    func setDisplayHold(_ held: Bool) async throws -> Bool {
        try await request { proxy, reply in
            proxy.setDisplayHold(held, reply: reply)
        }
    }

    private func request(
        _ send: (KAMHelperProtocol, @escaping (Bool, String?) -> Void) -> Void
    ) async throws -> Bool {
        // A request owns its connection, so retries cannot reuse an invalid one.
        let connection = makeConnection()
        var deadline: DispatchWorkItem?
        defer {
            deadline?.cancel()
            connection.invalidate()
        }

        return try await withCheckedThrowingContinuation { continuation in
            let reply = PendingReply(continuation)
            let unavailable = { reply.finish(.failure(HelperError.unavailable)) }
            connection.remoteObjectInterface = NSXPCInterface(with: KAMHelperProtocol.self)
            connection.invalidationHandler = unavailable
            connection.interruptionHandler = unavailable
            connection.resume()

            let timeoutWork = DispatchWorkItem {
                reply.finish(.failure(HelperError.timedOut))
            }
            deadline = timeoutWork
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                unavailable()
            }) as? KAMHelperProtocol else {
                unavailable()
                return
            }
            send(proxy) { ok, error in
                if let error = error {
                    reply.finish(.failure(HelperError.rejected(error)))
                } else {
                    reply.finish(.success(ok))
                }
            }
        }
    }

    private enum HelperError: LocalizedError {
        case unavailable
        case timedOut
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Keep-awake helper is unavailable. It may not be installed or approved."
            case .timedOut:
                return "Keep-awake helper did not respond in time. Try again."
            case .rejected(let message):
                return message
            }
        }
    }

    /// XPC callbacks and the timeout may race. Resume the continuation once.
    private final class PendingReply: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Error>?

        init(_ continuation: CheckedContinuation<Bool, Error>) {
            self.continuation = continuation
        }

        func finish(_ result: Result<Bool, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
        }
    }
}
