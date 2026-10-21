// RUN: %target-run-simple-swift( -swift-version 6 -Xfrontend -disable-availability-checking %import-libdispatch -parse-as-library) | %FileCheck %s
// RUN: %target-run-simple-swift( -swift-version 6 -enable-upcoming-feature NonisolatedNonsendingByDefault -Xfrontend -disable-availability-checking %import-libdispatch -parse-as-library) | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: libdispatch
// REQUIRES: concurrency_runtime
// REQUIRES: swift_feature_NonisolatedNonsendingByDefault
// UNSUPPORTED: back_deployment_runtime

// https://github.com/swiftlang/swift/issues/93432
// rdar://190427405
// An 'async' defer must inherit the isolation of its enclosing closure.

import Dispatch

actor Worker {
  func work() {}
}

@MainActor
final class Model {
  let worker = Worker()

  func methodDefer() async {
    defer {
      MainActor.preconditionIsolated("defer in a method")
      await worker.work()
    }
    await worker.work()
  }

  func inferredTaskDefer() -> Task<Void, Never> {
    Task {
      MainActor.preconditionIsolated("Task closure")
      defer {
        MainActor.preconditionIsolated("defer in a Task closure")
        await worker.work()
      }
      await worker.work()
    }
  }
}

actor Counter {
  let worker = Worker()

  func taskDefer() -> Task<Void, Never> {
    Task {
      self.preconditionIsolated("Task closure in an actor")
      defer {
        self.preconditionIsolated("defer in a Task closure in an actor")
        await worker.work()
      }
      await worker.work()
    }
  }
}

// The defer inherits the caller's isolation in a 'nonisolated(nonsending)' closure
@MainActor
func nonsendingClosureDefer() async {
  let body: nonisolated(nonsending) () async -> Void = {
    defer {
      MainActor.preconditionIsolated("defer in a nonisolated(nonsending) closure")
      await Worker().work()
    }
    await Worker().work()
  }
  await body()
}

// The defer inherits the isolation of the closure's 'isolated' parameter
func isolatedParameterClosureDefer(_ counter: Counter) async {
  let body: (isolated Counter) async -> Void = { counter in
    defer {
      counter.preconditionIsolated("defer in a closure with an isolated parameter")
      await Worker().work()
    }
    await Worker().work()
  }
  await body(counter)
}

// The defer inherits the isolation of an 'isolated' parameter captured by the closure
func capturedIsolatedParameterClosureDefer(isolated counter: isolated Counter) async {
  let body: () async -> Void = {
    counter.preconditionIsolated("closure capturing an isolated parameter")
    defer {
      counter.preconditionIsolated("defer in a closure capturing an isolated parameter")
      await Worker().work()
    }
    await Worker().work()
  }
  await body()
}

// Nested async defers inherit the isolation of the closure they are written in
@MainActor
func nestedDeferInMainActorTask() async {
  await Task {
    MainActor.preconditionIsolated("closure")
    defer {
      MainActor.preconditionIsolated("outer defer in a MainActor Task closure")
      defer {
        MainActor.preconditionIsolated("inner defer in a MainActor Task closure")
        await Worker().work()
        MainActor.preconditionIsolated("inner defer in a MainActor Task closure, after await")
      }
      await Worker().work()
      MainActor.preconditionIsolated("outer defer in a MainActor Task closure, after await")
    }
    await Worker().work()
  }.value
}

extension Counter {
  func nestedDeferInActorTask() async {
    await Task {
      self.preconditionIsolated("closure")
      defer {
        self.preconditionIsolated("outer defer in an actor Task closure")
        defer {
          self.preconditionIsolated("inner defer in an actor Task closure")
          await Worker().work()
          self.preconditionIsolated("inner defer in an actor Task closure, after await")
        }
        await Worker().work()
        self.preconditionIsolated("outer defer in an actor Task closure, after await")
      }
      await Worker().work()
    }.value
  }

  func nestedDeferInActorMethod() async {
    defer {
      self.preconditionIsolated("outer defer in an actor method")
      defer {
        self.preconditionIsolated("inner defer in an actor method")
        await Worker().work()
        self.preconditionIsolated("inner defer in an actor method, after await")
      }
      await Worker().work()
      self.preconditionIsolated("outer defer in an actor method, after await")
    }
    await Worker().work()
  }
}

// An 'async let' initializer never inherits the isolation of its parent, so
// neither does a defer in a closure in it: the defer is not isolated to the
// main actor, which is blocked until the defer has run.
@MainActor
func asyncLetDefer() async {
  let semaphore = DispatchSemaphore(value: 0)
  async let result: Int = {
    defer {
      precondition(#isolation == nil, "defer in an async let is not isolated")
      semaphore.signal()
      await Worker().work()
    }
    await Worker().work()
    return 42
  }()

  // The defer can only run, and signal, if it is not isolated to the main actor
  precondition(semaphore.wait(timeout: .now() + 10) == .success,
               "defer in an async let did not run off the main actor")
  let value = await result
  precondition(value == 42)
}

// '#isolation' in sync and async defers is always the isolation of the context
// the defer is written in
@MainActor
func currentIsolationInMainActorTaskDefers() async {
  await Task {
    defer {
      precondition(#isolation === MainActor.shared, "sync defer in a MainActor Task closure")
    }
    defer {
      precondition(#isolation === MainActor.shared, "async defer in a MainActor Task closure")
      await Worker().work()
      precondition(#isolation === MainActor.shared, "async defer in a MainActor Task closure, after await")
    }
    await Worker().work()
  }.value
}

extension Counter {
  func currentIsolationInActorDefers() async {
    // Closure isolated to the actor instance
    await Task {
      self.preconditionIsolated("closure")
      defer {
        precondition(#isolation === self, "sync defer in an actor Task closure")
      }
      defer {
        precondition(#isolation === self, "async defer in an actor Task closure")
        await Worker().work()
        precondition(#isolation === self, "async defer in an actor Task closure, after await")
      }
      await Worker().work()
    }.value

    // Method
    defer {
      precondition(#isolation === self, "sync defer in an actor method")
    }
    defer {
      precondition(#isolation === self, "async defer in an actor method")
      await Worker().work()
      precondition(#isolation === self, "async defer in an actor method, after await")
    }
    await Worker().work()
  }
}

func currentIsolationInIsolatedParameterDefers(isolated counter: isolated Counter) async {
  let body: () async -> Void = {
    defer {
      precondition(#isolation === counter, "sync defer in a closure capturing an isolated parameter")
    }
    defer {
      precondition(#isolation === counter, "async defer in a closure capturing an isolated parameter")
      await Worker().work()
      precondition(#isolation === counter, "async defer in a closure capturing an isolated parameter, after await")
    }
    await Worker().work()
  }
  await body()
}

// '#isolation' in defers that do not name the actor: the closure, and not the
// defer, is what refers to the actor
extension Counter {
  func asyncDeferIsolationInActorTask() async {
    await Task {
      self.preconditionIsolated("closure")
      var seen: (any Actor)? = nil
      do {
        defer { seen = #isolation; await Worker().work() }
        await Worker().work()
      }
      precondition(seen === self, "async defer in an actor Task closure")
    }.value
  }
}

@concurrent
func currentIsolationInConcurrentDefers() async {
  defer {
    precondition(#isolation == nil, "sync defer in a @concurrent function")
  }
  defer {
    precondition(#isolation == nil, "async defer in a @concurrent function")
    await Worker().work()
    precondition(#isolation == nil, "async defer in a @concurrent function, after await")
  }
  await Worker().work()
}

@main struct Main {
  static func main() async {
    let model = await Model()

    await model.methodDefer()
    print("defer in a method: ran on the main actor")
    // CHECK: defer in a method: ran on the main actor

    await model.inferredTaskDefer().value
    print("defer in an inferred @MainActor Task closure: ran on the main actor")
    // CHECK: defer in an inferred @MainActor Task closure: ran on the main actor

    await Task { @MainActor in
      defer {
        MainActor.preconditionIsolated("defer in an explicit @MainActor Task closure")
        await model.worker.work()
      }
      await model.worker.work()
    }.value
    print("defer in an explicit @MainActor Task closure: ran on the main actor")
    // CHECK: defer in an explicit @MainActor Task closure: ran on the main actor

    await Counter().taskDefer().value
    print("defer in an actor Task closure: ran on the actor")
    // CHECK: defer in an actor Task closure: ran on the actor

    await nonsendingClosureDefer()
    print("defer in a nonisolated(nonsending) closure: ran on the caller's actor")
    // CHECK: defer in a nonisolated(nonsending) closure: ran on the caller's actor

    await isolatedParameterClosureDefer(Counter())
    print("defer in an isolated parameter closure: ran on the parameter's actor")
    // CHECK: defer in an isolated parameter closure: ran on the parameter's actor

    await capturedIsolatedParameterClosureDefer(isolated: Counter())
    print("defer in a closure capturing an isolated parameter: ran on the parameter's actor")
    // CHECK: defer in a closure capturing an isolated parameter: ran on the parameter's actor

    await nestedDeferInMainActorTask()
    print("nested defers in a MainActor Task closure: ran on the main actor")
    // CHECK: nested defers in a MainActor Task closure: ran on the main actor

    await Counter().nestedDeferInActorTask()
    print("nested defers in an actor Task closure: ran on the actor")
    // CHECK: nested defers in an actor Task closure: ran on the actor

    await Counter().nestedDeferInActorMethod()
    print("nested defers in an actor method: ran on the actor")
    // CHECK: nested defers in an actor method: ran on the actor

    await asyncLetDefer()
    print("defer in an async let: ran off the main actor")
    // CHECK: defer in an async let: ran off the main actor

    await currentIsolationInMainActorTaskDefers()
    await Counter().currentIsolationInActorDefers()
    await currentIsolationInIsolatedParameterDefers(isolated: Counter())
    await currentIsolationInConcurrentDefers()
    print("#isolation in defers: always the isolation of the enclosing context")
    // CHECK: #isolation in defers: always the isolation of the enclosing context

    await Counter().asyncDeferIsolationInActorTask()
    print("#isolation in defers that do not name the actor: the isolation of the closure")
    // CHECK: #isolation in defers that do not name the actor: the isolation of the closure
  }
}
