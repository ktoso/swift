// RUN: %target-swift-frontend -emit-sil -O -sil-verify-all %s -o /dev/null

// Reduced from the Async{Throwing}Stream state-machine reimplementation
// (https://github.com/swiftlang/swift/pull/88017). Compiling _Concurrency with
// SIL verification enabled used to abort while optimizing the `yield` overload
// specialized for an empty-tuple element type:
//
//   Error! Found a leaked owned value that was never consumed.
//   Value:   %11 = struct $Disconnected<()> (%6 : $Optional<()>)
//   ...
//   While running pass Mem2Reg on '...yield...yt_s5NeverOTg5'
//   While verifying SIL function ...
//
// Root cause: when the noncopyable `Disconnected` wrapper is specialized for a
// trivial, empty-tuple payload (`Value == ()`) and consumed through a closure,
// Mem2Reg promotes the wrapper's stack slot but fails to insert the cleanup for
// the owned value, leaving it leaked. Without `-sil-verify-all` the bad SIL is
// silently emitted instead of caught, so this must build cleanly under it.

// The owned, noncopyable wrapper around an optional payload
struct Disconnected<Value: ~Copyable>: ~Copyable {
  private var value: Value?

  private init() {
    self.value = nil
  }

  init(_ value: consuming Value) {
    self.value = consume value
  }

  mutating func take() -> Value {
    let oldValue = consume value
    self = .init()
    return oldValue!
  }
}

// Consuming `take()` inside a closure passed to a generic function is what keeps
// the wrapper's stack slot alive until the failing Mem2Reg run
func withLock<R>(_ body: () -> R) -> R {
  return body()
}

public func go<Element>(_ value: consuming Element) -> Element {
  var disconnected = Disconnected(value)
  return withLock {
    return disconnected.take()
  }
}

// Forces the `Element == ()` specialization that trips the verifier
public func trigger(_ value: ()) -> () {
  return go(())
}
