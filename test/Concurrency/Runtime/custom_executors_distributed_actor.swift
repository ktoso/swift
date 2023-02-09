// RUN: %target-run-simple-swift( -Xfrontend -disable-availability-checking %import-libdispatch -parse-as-library) | %FileCheck %s

// REQUIRES: concurrency
// REQUIRES: executable_test
// REQUIRES: libdispatch
// UNSUPPORTED: freestanding

// UNSUPPORTED: back_deployment_runtime
// REQUIRES: concurrency_runtime

import Dispatch
import Distributed

func checkIfMainQueue(expectedAnswer expected: Bool) {
  dispatchPrecondition(condition: expected ? .onQueue(DispatchQueue.main)
      : .notOnQueue(DispatchQueue.main))
}

protocol SpecifiedExecutor: SerialExecutor {}

final class InlineExecutor: SpecifiedExecutor, Swift.CustomStringConvertible {
  let name: String

  init(_ name: String) {
    self.name = name
  }

  public func enqueue(_ job: UnownedJob) {
    print("\(self): enqueue")
    job._runSynchronously(on: self.asUnownedSerialExecutor())
    print("\(self): after run")
  }

  public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
    return UnownedSerialExecutor(ordinary: self)
  }

  var description: Swift.String {
    "InlineExecutor(\(name))"
  }
}

distributed actor MyDefaultDistributedActor {
  typealias ActorSystem = LocalTestingDistributedActorSystem
  let executor: any SpecifiedExecutor

//  nonisolated var unownedExecutor: UnownedSerialExecutor {
//    print("\(Self.self): unownedExecutor - start")
//    if __isLocalActor(self) {
//    print("\(Self.self): unownedExecutor - isLocal")
//      let __secretlyKnownToBeLocal = self
//      print("\(Self.self): unownedExecutor - return ...")
//      return __secretlyKnownToBeLocal.executor.asUnownedSerialExecutor()
//    } else {
//      print("\(Self.self): unownedExecutor - return Main")
//      return MainActor.sharedUnownedExecutor
//    }
//  }

  init(executor: some SpecifiedExecutor, actorSystem: ActorSystem) {
    self.actorSystem = actorSystem
    self.executor = executor
  }

  distributed func test(
      expectMainQueue: Bool
//      expectedExecutor: some SerialExecutor
  ) {
//    precondition(_taskIsOnExecutor(expectedExecutor), "Expected to be on: \(expectedExecutor)")
    checkIfMainQueue(expectedAnswer: expectMainQueue)
    print("\(Self.self): on executor \(self.executor)")
  }
}

distributed actor MyCustomDistributedActor {
  typealias ActorSystem = LocalTestingDistributedActorSystem
  let executor: any SpecifiedExecutor

  nonisolated var unownedExecutor: UnownedSerialExecutor {
    print("\(Self.self): unownedExecutor - start")
    if __isLocalActor(self) {
    print("\(Self.self): unownedExecutor - isLocal")
      let __secretlyKnownToBeLocal = self
      print("\(Self.self): unownedExecutor - return ...")
      return __secretlyKnownToBeLocal.executor.asUnownedSerialExecutor()
    } else {
      print("\(Self.self): unownedExecutor - return Main")
      return MainActor.sharedUnownedExecutor
    }
  }

  init(executor: some SpecifiedExecutor, actorSystem: ActorSystem) {
    self.actorSystem = actorSystem
    self.executor = executor
  }

  distributed func test(
      expectMainQueue: Bool
//      expectedExecutor: some SerialExecutor
  ) {
//    precondition(_taskIsOnExecutor(expectedExecutor), "Expected to be on: \(expectedExecutor)")
    checkIfMainQueue(expectedAnswer: expectMainQueue)
    print("\(Self.self): on executor \(self.executor)")
  }
}

@main struct Main {
  static func main() async throws {
    let one = InlineExecutor("one")
    let actorSystem = LocalTestingDistributedActorSystem()

    print("begin")
    let actorDefault = MyDefaultDistributedActor(executor: one, actorSystem: actorSystem)
    try await actorDefault.test(expectMainQueue: false/*, expectedExecutor: one*/)
    try await actorDefault.test(expectMainQueue: false/*, expectedExecutor: one*/)
    try await actorDefault.test(expectMainQueue: false/*, expectedExecutor: one*/)
    print("end")

    print("begin")
    let actorCustom = MyCustomDistributedActor(executor: one, actorSystem: actorSystem)
    try await actorCustom.test(expectMainQueue: false/*, expectedExecutor: one*/)
    try await actorCustom.test(expectMainQueue: false/*, expectedExecutor: one*/)
    try await actorCustom.test(expectMainQueue: false/*, expectedExecutor: one*/)
    print("end")
  }
}

@_silgen_name("swift_distributed_actor_is_remote")
func __isRemoteActor(_ actor: AnyObject) -> Bool

func __isLocalActor(_ actor: AnyObject) -> Bool {
  return !__isRemoteActor(actor)
}

// CHECK:      begin
// CHECK-NEXT: InlineExecutor(one): enqueue
// CHECK-NEXT: MyDefaultDistributedActor: on executor
// CHECK-NEXT: MyDefaultDistributedActor: on executor
// CHECK-NEXT: MyDefaultDistributedActor: on executor
// CHECK-NEXT: end
// CHECK-NEXT: begin
// CHECK-NEXT: InlineExecutor(one): enqueue
// CHECK-NEXT: MyCustomDistributedActor: on executor InlineExecutor(one)
// CHECK-NEXT: MyCustomDistributedActor: on executor InlineExecutor(one)
// CHECK-NEXT: MyCustomDistributedActor: on executor InlineExecutor(one)
// CHECK-NEXT: InlineExecutor(one): after run
// CHECK-NEXT: end
