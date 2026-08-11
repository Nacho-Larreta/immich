import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private final class CountingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var starts = 0

    static var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.starts += 1
        Self.lock.unlock()
    }

    override func stopLoading() {}
}

private final class CallbackURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
private struct StreamingTaskLifecycleHarness {
    static func main() {
        callbackGateWaitsForAdmittedCallbacks()
        callbackCanCancelWhileReapWaits()
        reapIsIdempotentAndPreventsStart()
        reaperReleasesItsRetainedTokenExactlyOnce()
    }

    private static func callbackGateWaitsForAdmittedCallbacks() {
        let gate = _StreamingCallbackGate()
        require(gate.enter(), "first callback must be admitted")
        let reaped = DispatchSemaphore(value: 0)
        let cleanup = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            gate.tombstoneAndWait { cleanup.signal() }
            reaped.signal()
        }

        require(cleanup.wait(timeout: .now() + 0.03) == .timedOut, "reap crossed an admitted callback")
        gate.leave()
        require(reaped.wait(timeout: .now() + 1) == .success, "reap did not finish after callback exit")
        require(!gate.enter(), "callback was admitted after reap")
    }

    private static func callbackCanCancelWhileReapWaits() {
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let callbackFinished = DispatchSemaphore(value: 0)
        let reaped = DispatchSemaphore(value: 0)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CallbackURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var task: CUPHTTPStreamingTask!
        task = CUPHTTPStreamingTask(
            session: session,
            request: URLRequest(url: URL(string: "https://lifecycle.invalid/callback")!),
            onResponse: { _, _ in
                entered.signal()
                _ = proceed.wait(timeout: .now() + 1)
                task.cancel()
                callbackFinished.signal()
            },
            onData: nil,
            onComplete: nil,
            maxRedirects: 0
        )
        task.start()
        require(entered.wait(timeout: .now() + 1) == .success, "response callback was not admitted")
        DispatchQueue.global().async {
            task.reap()
            reaped.signal()
        }
        Thread.sleep(forTimeInterval: 0.03)
        proceed.signal()
        require(callbackFinished.wait(timeout: .now() + 1) == .success, "callback deadlocked against reap")
        require(reaped.wait(timeout: .now() + 1) == .success, "reap did not wait for callback completion")
    }

    private static func reapIsIdempotentAndPreventsStart() {
        let task = makeTask()
        task.reap()
        task.reap()
        task.start()
        Thread.sleep(forTimeInterval: 0.03)
        require(CountingURLProtocol.startCount == 0, "reaped task resumed native transport")
    }

    private static func reaperReleasesItsRetainedTokenExactlyOnce() {
        var task: CUPHTTPStreamingTask? = makeTask()
        weak let weakTask = task
        let token = Unmanaged.passRetained(task!).toOpaque()
        task = nil
        let reaper = unsafeBitCast(
            CUPHTTPStreamingTask.taskReaper(),
            to: (@convention(c) (UnsafeMutableRawPointer) -> Void).self
        )
        reaper(token)
        require(weakTask == nil, "reaper did not release its retained token")
    }

    private static func makeTask() -> CUPHTTPStreamingTask {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return CUPHTTPStreamingTask(
            session: session,
            request: URLRequest(url: URL(string: "https://lifecycle.invalid/test")!),
            onResponse: nil,
            onData: nil,
            onComplete: nil,
            maxRedirects: 0
        )
    }
}
