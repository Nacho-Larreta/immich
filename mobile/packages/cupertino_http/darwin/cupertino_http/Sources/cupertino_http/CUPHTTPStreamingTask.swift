// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import Foundation

/// A streaming HTTP task helper for externally-managed URLSessions.
@objc(CUPHTTPStreamingTask)
public class CUPHTTPStreamingTask: NSObject {
    private let session: URLSession
    private let request: URLRequest
    private let maxRedirects: Int
    private let state = NSLock()
    /// Internal data task reference for cancellation.
    private var dataTask: URLSessionDataTask?
    /// Strong reference keeps the delegate alive for the task's lifetime.
    private var taskDelegate: _StreamingTaskDelegate?
    private var started = false
    private var cancelRequested = false
    private var nativeCancelIssued = false
    private var reaped = false
    private var onResponse: ((URLResponse?, NSError?) -> Void)?
    private var onData: ((NSData) -> Void)?
    private var onComplete: ((NSError?) -> Void)?

    @objc public var numRedirects: Int { taskDelegate?.numRedirects ?? 0 }
    @objc public var lastURL: URL? { taskDelegate?.lastURL }

    /// Creates a new streaming task with callback blocks.
    ///
    /// - Parameters:
    ///   - session: The URLSession to use (can be externally managed)
    ///   - request: The URL request to execute
    ///   - onResponse: Called once when response headers are available
    ///   - onData: Called repeatedly with buffered data chunks
    ///   - onComplete: Called once when the request completes
    @objc
    public init(
        session: URLSession,
        request: URLRequest,
        onResponse: ((URLResponse?, NSError?) -> Void)?,
        onData: ((NSData) -> Void)?,
        onComplete: ((NSError?) -> Void)?,
        maxRedirects: Int
    ) {
        self.session = session
        self.request = request
        self.onResponse = onResponse
        self.onData = onData
        self.onComplete = onComplete
        self.maxRedirects = maxRedirects
        super.init()
    }

    /// Starts the streaming request.
    ///
    /// Requires iOS 15+ / macOS 12+ for per-task delegate support.
    @objc
    public func start() {
        state.lock()
        guard beginStart() else {
            state.unlock()
            return
        }

        guard #available(iOS 15.0, macOS 12.0, *) else {
            let callback = onComplete
            clearPendingCallbacks()
            state.unlock()
            callback?(
                NSError(
                    domain: "CUPHTTPStreamingTask",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Per-task delegates require iOS 15+ / macOS 12+"]
                )
            )
            return
        }

        let delegate = _StreamingTaskDelegate(
            onResponse: onResponse,
            onData: onData,
            onComplete: onComplete,
            maxRedirects: maxRedirects
        )
        clearPendingCallbacks()
        let task = session.dataTask(with: request)
        task.delegate = delegate
        taskDelegate = delegate
        dataTask = task
        if !cancelRequested {
            task.resume()
        } else if !nativeCancelIssued {
            nativeCancelIssued = true
            task.cancel()
        }
        state.unlock()
    }

    private func beginStart() -> Bool {
        guard !started, !reaped else { return false }
        started = true
        return true
    }

    /// Cancels the in-flight request.
    @objc
    public func cancel() {
        state.lock()
        cancelRequested = true
        let task = claimTaskForCancellation()
        state.unlock()
        task?.cancel()
    }

    func reap() {
        state.lock()
        guard !reaped else {
            state.unlock()
            return
        }
        reaped = true
        cancelRequested = true
        let delegate = taskDelegate
        clearPendingCallbacks()
        let task = claimTaskForCancellation()
        state.unlock()
        delegate?.tombstoneAndWait()
        task?.cancel()
    }

    private func claimTaskForCancellation() -> URLSessionDataTask? {
        guard !nativeCancelIssued, let dataTask else { return nil }
        nativeCancelIssued = true
        return dataTask
    }

    private func clearPendingCallbacks() {
        onResponse = nil
        onData = nil
        onComplete = nil
    }

    @objc
    public static func taskReaper() -> UnsafeMutableRawPointer {
        unsafeBitCast(taskReaperImpl, to: UnsafeMutableRawPointer.self)
    }
}

private let taskReaperImpl: @convention(c) (UnsafeMutableRawPointer) -> Void = { pointer in
    let object = Unmanaged<NSObject>.fromOpaque(pointer).takeRetainedValue()
    switch object {
    case let task as CUPHTTPStreamingTask:
        task.reap()
    case let task as CUPHTTPWebSocketTask:
        task.cancel()
    case let task as URLSessionTask:
        task.cancel()
    default:
        break
    }
}

final class _StreamingCallbackGate {
    private let condition = NSCondition()
    private var callbacksAllowed = true
    private var callbacksInFlight = 0

    func enter() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard callbacksAllowed else { return false }
        callbacksInFlight += 1
        return true
    }

    func leave() {
        condition.lock()
        callbacksInFlight -= 1
        if callbacksInFlight == 0 { condition.broadcast() }
        condition.unlock()
    }

    func tombstoneAndWait(_ clearCallbacks: () -> Void) {
        condition.lock()
        callbacksAllowed = false
        while callbacksInFlight > 0 {
            condition.wait()
        }
        clearCallbacks()
        condition.unlock()
    }
}

/// Per-task data delegate that handles only streaming delivery.
///
/// Any delegate method implemented here is used in place of the session-level
/// delegate implementation, so adding overrides is a breaking change.
private final class _StreamingTaskDelegate: NSObject, URLSessionDataDelegate {
    private let gate = _StreamingCallbackGate()
    private var onResponse: ((URLResponse?, NSError?) -> Void)?
    private var onData: ((NSData) -> Void)?
    private var onComplete: ((NSError?) -> Void)?
    private var responseDelivered = false
    private let maxRedirects: Int
    private(set) var numRedirects = 0
    private(set) var lastURL: URL?

    init(
        onResponse: ((URLResponse?, NSError?) -> Void)?,
        onData: ((NSData) -> Void)?,
        onComplete: ((NSError?) -> Void)?,
        maxRedirects: Int
    ) {
        self.onResponse = onResponse
        self.onData = onData
        self.onComplete = onComplete
        self.maxRedirects = maxRedirects
        super.init()
    }

    func tombstoneAndWait() {
        gate.tombstoneAndWait {
            self.onResponse = nil
            self.onData = nil
            self.onComplete = nil
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard gate.enter() else {
            completionHandler(.cancel)
            return
        }
        defer { gate.leave() }
        responseDelivered = true
        let callback = onResponse
        onResponse = nil
        callback?(response, nil)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard gate.enter() else { return }
        defer { gate.leave() }
        onData?(data as NSData)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard gate.enter() else { return }
        defer { gate.leave() }
        let nsError = error.map { $0 as NSError }
        if !responseDelivered {
            let responseCallback = onResponse
            onResponse = nil
            responseCallback?(nil, nsError)
        }
        let completeCallback = onComplete
        onComplete = nil
        onData = nil
        completeCallback?(nsError)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard gate.enter() else {
            completionHandler(nil)
            return
        }
        defer { gate.leave() }
        numRedirects += 1
        guard numRedirects <= maxRedirects else {
            completionHandler(nil)
            return
        }
        lastURL = request.url
        completionHandler(request)
    }
}
