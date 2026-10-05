// RUN: %target-run-simple-swift( -parse-as-library)

// REQUIRES: concurrency
// REQUIRES: executable_test
// REQUIRES: concurrency_runtime
// REQUIRES: synchronization

// UNSUPPORTED: back_deployment_runtime
// UNSUPPORTED: freestanding
// XFAIL: OS=emscripten

// rdar://156074753 / https://github.com/swiftlang/swift/issues/83137
// AsyncStream(unfolding:onCancel:) must call onCancel at most once.

import _Concurrency
import StdlibUnittest
import Synchronization

@available(SwiftStdlib 6.2, *)
final class Gate: Sendable {
  private let continuation = Mutex<CheckedContinuation<Void, Never>?>(nil)

  /// Suspends until `open()` is called, without observing cancellation.
  /// `onSuspended` runs once the continuation is installed, so `open()` can
  /// no longer be missed.
  func wait(onSuspended: () -> Void) async {
    await withCheckedContinuation { c in
      continuation.withLock { $0 = c }
      onSuspended()
    }
  }

  func open() {
    continuation.withLock { $0.take() }!.resume()
  }
}

@MainActor var tests = TestSuite("AsyncStreamUnfoldingCancel")

@main struct Main {
  static func main() async {
    if #available(SwiftStdlib 6.2, *) {

      tests.test("onCancel once when producer ignores cancellation") {
        let cancelCount = Mutex(0)
        let produceCount = Mutex(0)
        let gate = Gate()
        let (suspended, suspendedContinuation) = AsyncStream.makeStream(of: Void.self)

        let stream = AsyncStream<Int>(unfolding: {
          let n = produceCount.withLock { $0 += 1; return $0 }
          // Ignore cancellation and produce a value regardless.
          await gate.wait { suspendedContinuation.yield() }
          return n
        }, onCancel: {
          cancelCount.withLock { $0 += 1 }
        })

        let task = Task {
          var values: [Int] = []
          for await value in stream { values.append(value) }
          return values
        }

        // Wait until the first next() is suspended inside the producer.
        for await _ in suspended { break }
        task.cancel()
        expectEqual(cancelCount.withLock { $0 }, 1)
        gate.open()

        // The in-flight element is still delivered, then the stream ends.
        let values = await task.value
        expectEqual(values, [1])
        expectEqual(produceCount.withLock { $0 }, 1)
        expectEqual(cancelCount.withLock { $0 }, 1)
      }

      tests.test("onCancel once when cancelled during suspended next()") {
        let cancelCount = Mutex(0)
        let (suspended, suspendedContinuation) = AsyncStream.makeStream(of: Void.self)

        let stream = AsyncStream<Int>(unfolding: {
          // Honour cancellation: suspend until cancelled, then finish.
          suspendedContinuation.yield()
          try? await Task.sleep(for: .seconds(3600))
          return Task.isCancelled ? nil : 1
        }, onCancel: {
          cancelCount.withLock { $0 += 1 }
        })

        let task = Task {
          var values: [Int] = []
          for await value in stream { values.append(value) }
          // Further next() calls after termination must not re-fire onCancel.
          var iterator = stream.makeAsyncIterator()
          expectNil(await iterator.next())
          return values
        }

        for await _ in suspended { break }
        task.cancel()

        let values = await task.value
        expectEqual(values, [])
        expectEqual(cancelCount.withLock { $0 }, 1)
      }

      tests.test("onCancel once when cancelled after normal finish") {
        let cancelCount = Mutex(0)
        let produceCount = Mutex(0)

        let stream = AsyncStream<Int>(unfolding: {
          produceCount.withLock { $0 += 1; return $0 <= 2 ? $0 : nil }
        }, onCancel: {
          cancelCount.withLock { $0 += 1 }
        })

        let task = Task {
          var iterator = stream.makeAsyncIterator()
          expectEqual(await iterator.next(), 1)
          expectEqual(await iterator.next(), 2)
          expectNil(await iterator.next())
          withUnsafeCurrentTask { $0?.cancel() }
          expectNil(await iterator.next())
          expectNil(await iterator.next())
        }

        await task.value
        expectEqual(produceCount.withLock { $0 }, 3)
        expectEqual(cancelCount.withLock { $0 }, 1)
      }

      tests.test("onCancel once when producer finishes after observing cancellation") {
        await producerObservingCancellation(iterations: 200)
      }
    }

    await runAllTestsAsync()
  }

  /// The producer polls for cancellation without suspending and returns `nil`
  /// as soon as it sees it, racing the cancellation handler that calls
  /// `onCancel`. Clearing the producer must not consume `onCancel`, so it is
  /// called exactly once. The cancelling side runs on the main actor so it
  /// never competes with the spinning producer for a cooperative pool thread
  @available(SwiftStdlib 6.2, *)
  @MainActor
  static func producerObservingCancellation(iterations: Int) async {
    var counts: [Int: Int] = [:]
    for _ in 0..<iterations {
      let cancelCount = Mutex(0)
      let started = Mutex<CheckedContinuation<Void, Never>?>(nil)

      let stream = AsyncStream<Int>(unfolding: {
        started.withLock { $0.take() }?.resume()
        // Fall back to yielding after a while, so a single-threaded pool
        // can't deadlock the test
        let deadline = ContinuousClock.now + .seconds(1)
        var spins = 0
        while !Task.isCancelled {
          spins &+= 1
          if spins & 4095 == 0, ContinuousClock.now > deadline {
            await Task.yield()
          }
        }
        return nil
      }, onCancel: {
        cancelCount.withLock { $0 += 1 }
      })

      var task: Task<Void, Never>!
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        started.withLock { $0 = c }
        task = Task.detached {
          for await _ in stream {}
          // If the producer returned before cancellation reached the stream's
          // handler, that handler never ran; a further next() on the
          // cancelled task runs it immediately, and it must still find
          // `onCancel`
          var iterator = stream.makeAsyncIterator()
          _ = await iterator.next()
        }
      }
      task.cancel()
      await task.value
      counts[cancelCount.withLock { $0 }, default: 0] += 1
    }
    expectEqual(counts, [1: iterations])
  }
}
