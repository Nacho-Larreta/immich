import XCTest

final class SupportHarnessTests: XCTestCase {
  func testManualSchedulerRunsDeterministicallyWithoutSleeping() {
    let scheduler = ManualScheduler()
    var events: [String] = []
    scheduler.schedule(after: 2) { events.append("second") }
    let cancelled = scheduler.schedule(after: 1) { events.append("cancelled") }
    scheduler.schedule(after: 1) { events.append("first") }
    cancelled.cancel()

    scheduler.advance(by: 2)

    XCTAssertEqual(events, ["first", "second"])
    XCTAssertEqual(scheduler.clock.now, 2)
  }

  func testControlledRequestCompletesExactlyOnce() {
    let request = ControlledRequest<Int>()
    let recorder = CompletionRecorder<Int>()
    request.onComplete { _ = recorder.record($0) }

    XCTAssertTrue(request.succeed(42))
    XCTAssertFalse(request.cancel())
    XCTAssertEqual(recorder.count, 1)
    XCTAssertEqual(try? recorder.result?.get(), 42)
  }

  func testConcurrencyCounterReleasesEachLeaseOnce() {
    let counter = ConcurrencyCounter()
    let first = counter.begin()
    let second = counter.begin()

    XCTAssertEqual(counter.active, 2)
    XCTAssertEqual(counter.peak, 2)
    first.release()
    first.release()
    second.release()

    XCTAssertEqual(counter.active, 0)
    XCTAssertEqual(counter.peak, 2)
  }

  func testControllableURLProtocolDeliversAControlledResponse() {
    let context = URLSessionTestFactory.make()
    let completion = expectation(description: "URLSession completion")
    ControllableURLProtocol.setRequestHandler { request in
      XCTAssertTrue(request.respond(statusCode: 200))
      XCTAssertTrue(request.send(Data("ok".utf8)))
      XCTAssertTrue(request.finish())
      XCTAssertFalse(request.finish())
    }

    context.session
      .dataTask(with: URL(string: "https://photos.example.test/ping")!) {
        data,
        response,
        error in
        XCTAssertNil(error)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, Data("ok".utf8))
        completion.fulfill()
      }
      .resume()

    wait(for: [completion], timeout: 1)
    XCTAssertEqual(ControllableURLProtocol.observedRequests.count, 1)
    context.reset()
  }
}
