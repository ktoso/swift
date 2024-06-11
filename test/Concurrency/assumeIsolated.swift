// RUN: %target-build-swift -swift-version 5 %s -strict-concurrency=complete -Xfrontend -verify

// REQUIRES: concurrency
// REQUIRES: OS=macosx

class NonSendableKlass {}

@available(macOS 10.15, *)
actor MyActor {
  var x = NonSendableKlass()

  nonisolated func doSomething() -> NonSendableKlass {
    return self.assumeIsolated { isolatedSelf in
      let x: NonSendableKlass = isolatedSelf.x
      return x
    }
  }

  nonisolated func doSomething2() -> NonSendableKlass {
    let r: NonSendableKlass = assumeIsolated { isolatedSelf in
      let x: NonSendableKlass = isolatedSelf.x
      return x
    }
    return r
  }
}

// ==== ----------------------------------------------------------------------------------------------------------------

@available(macOS 10.15, *)
actor Actor1 {
  var x: NonSendableKlass

  init(x: NonSendableKlass) {
    self.x = x
  }

  nonisolated func get() -> NonSendableKlass {
    return self.assumeIsolated { isolatedSelf in // allowed...
      return isolatedSelf.x // [1] we're allowed to return this...
    }
  }
}

@available(macOS 10.15, *)
actor Actor2 {
  var x: NonSendableKlass

  init(x: NonSendableKlass) {
    self.x = x
  }

  func take(_ x: NonSendableKlass) {
    self.x = x
  }
}

@available(macOS 10.15, *)
func unsound(actor1: Actor1, actor2: Actor2) async {
  let nonSendable = actor1.get()
  await actor2.take(nonSendable)
  // `nonSendable` crosses actor boundaries!
}