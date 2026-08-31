// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend -target %target-cpu-apple-macos14 -enable-experimental-feature Embedded -parse-as-library -plugin-path %swift-plugin-dir %s -c -o %t/a.o
// RUN: %target-embedded-link %t/a.o %target-embedded-posix-shim -o %t/a.out -L%swift_obj_root/lib/swift/embedded/%module-target-triple %target-clang-resource-dir-opt -lswift_Concurrency -lswiftDistributed %target-swift-default-executor-opt %target-embedded-concurrency-threading-shim -dead_strip
// RUN: %target-run %t/a.out | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: optimized_stdlib
// REQUIRES: OS=macosx || OS=wasip1
// REQUIRES: swift_feature_Embedded

// Phase 2 roundtrip: a `@Resolvable` protocol parameter flows over the
// stub transport as the macro-generated `$P` proxy. The sender thunk
// substitutes `$P` at the wire level; the receive-side dispatch decodes
// `$P` and lets the existential conversion to `any P` happen at the
// call into the user-declared body.
//
// The wire-level target identifier for a call made through a `$P` proxy
// (e.g. `someWorker.work(...)` where `someWorker: any RWorker` is a
// `$RWorker` instance) is the mangled name of `$P.<method>`'s thunk,
// NOT of the concrete actor's method. The synthesized
// `_executeDistributedTarget` on the concrete actor recognizes both
// target identifiers - one for direct concrete-actor calls, one for
// `@Resolvable`-proxied calls - and dispatches to `self.<method>`
// dynamically.

import _Concurrency
import Distributed

// ==== ----------------------------------------------------------------------
// MARK: A tiny in-memory transport (single-process)

final class CallBuffer {
  var argString: String?
  var argWorker: $RWorker?
  var returnString: String?
  var returnWorker: $RWorker?

  init() {}
}

// ==== ----------------------------------------------------------------------
// MARK: Encoder / Decoder / ResultHandler with $RWorker overloads

public struct MyEncoder: EmbeddedDistributedTargetInvocationEncoder {
  let buffer: CallBuffer
  init(buffer: CallBuffer) { self.buffer = buffer }

  public mutating func doneRecording() throws {}
}
extension MyEncoder {
  public mutating func recordArgument(_ argument: RemoteCallArgument<String>) throws {
    buffer.argString = argument.value
  }
  public mutating func recordArgument(_ argument: RemoteCallArgument<$RWorker>) throws {
    buffer.argWorker = argument.value
  }
  public mutating func recordReturnType(_ type: String.Type) throws {}
  public mutating func recordReturnType(_ type: $RWorker.Type) throws {}
}

public struct MyDecoder: EmbeddedDistributedTargetInvocationDecoder {
  let buffer: CallBuffer
  init(buffer: CallBuffer) { self.buffer = buffer }
}
extension MyDecoder {
  public mutating func decodeNextArgument(_ type: String.Type) throws -> String {
    guard let v = buffer.argString else { fatalError("missing arg") }
    buffer.argString = nil
    return v
  }
  public mutating func decodeNextArgument(_ type: $RWorker.Type) throws -> $RWorker {
    guard let v = buffer.argWorker else { fatalError("missing arg") }
    buffer.argWorker = nil
    return v
  }
}

public struct MyResultHandler: EmbeddedDistributedTargetInvocationResultHandler {
  let buffer: CallBuffer
  init(buffer: CallBuffer) { self.buffer = buffer }

  public func onReturnVoid() async throws {}
  public func onThrow(error: any Error) async throws {
    fatalError("threw in handler")
  }
}
extension MyResultHandler {
  public func onReturn(_ value: String) async throws {
    buffer.returnString = value
  }
  public func onReturn(_ value: $RWorker) async throws {
    buffer.returnWorker = value
  }
}

// ==== ----------------------------------------------------------------------
// MARK: The actor system

public struct MyActorID: Sendable, Hashable {
  public let id: UInt64
  public init(id: UInt64) { self.id = id }
}

public final class MySystem: EmbeddedDistributedActorSystem, @unchecked Sendable {
  public typealias ActorID = MyActorID
  public typealias InvocationEncoder = MyEncoder
  public typealias InvocationDecoder = MyDecoder
  public typealias ResultHandler = MyResultHandler

  // The system keeps the local instances around. Routing through
  // `remoteCall` finds the registered local actor by id and dispatches
  // to it via `_executeDistributedTarget`
  var hub: Hub?
  var worker: WorkerImpl?
  var hubAssigned = false
  let buffer = CallBuffer()

  public init() {}

  public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
      where Act: DistributedActor, Act.ID == ActorID {
    return nil
  }
  public func assignID<Act>(_ actorType: Act.Type) -> ActorID
      where Act: DistributedActor, Act.ID == ActorID {
    // Embedded has no `_swift_dynamicCastMetatype`, so don't case on
    // the metatype here; the test sets up the Hub first (id=42), then
    // the WorkerImpl (id=7)
    if hubAssigned == false {
      hubAssigned = true
      return MyActorID(id: 42)
    }
    return MyActorID(id: 7)
  }
  public func actorReady<Act>(_ actor: Act)
      where Act: DistributedActor, Act.ID == ActorID {
    if actor.id.id == 42 {
      self.hub = (actor as! AnyObject) as? Hub
    } else if actor.id.id == 7 {
      self.worker = (actor as! AnyObject) as? WorkerImpl
    }
  }
  public func resignID(_ id: ActorID) {}

  public func makeInvocationEncoder() -> InvocationEncoder {
    .init(buffer: buffer)
  }

  public func remoteCall<Act>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder
  ) async throws -> InvocationDecoder
      where Act: DistributedActor, Act.ID == ActorID {
    print("[swift] remoteCall reached")
    var decoder = MyDecoder(buffer: buffer)
    let handler = MyResultHandler(buffer: buffer)

    // Route by the receiver actor's ID (not its Swift type): when
    // dispatching through `any RWorker` -> `$RWorker` proxy, this
    // is the proxy, but the registered local instance for id=7 is the
    // concrete `WorkerImpl`. The synthesized `_executeDistributedTarget`
    // matches either the concrete `WorkerImpl.<method>` target identifier
    // or the `$RWorker.<method>` (`@Resolvable` proxy thunk) identifier,
    // routing to `self.<method>` either way
    if actor.id.id == 42 {
      guard let h = self.hub else { fatalError("no local Hub") }
      try await h._executeDistributedTarget(
          target: target,
          invocationDecoder: &decoder,
          resultHandler: handler)
    } else if actor.id.id == 7 {
      guard let w = self.worker else { fatalError("no local Worker") }
      try await w._executeDistributedTarget(
          target: target,
          invocationDecoder: &decoder,
          resultHandler: handler)
    } else {
      fatalError("unknown actor id")
    }

    // Wire the response back into a fresh decoder
    buffer.argString = buffer.returnString
    buffer.argWorker = buffer.returnWorker
    buffer.returnString = nil
    buffer.returnWorker = nil
    return MyDecoder(buffer: buffer)
  }

  public func remoteCallVoid<Act>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder
  ) async throws
      where Act: DistributedActor, Act.ID == ActorID {
    fatalError("not implemented in this test")
  }
}

typealias DefaultDistributedActorSystem = MySystem

// ==== ----------------------------------------------------------------------
// MARK: The @Resolvable protocol and a concrete implementation

@Resolvable
public protocol RWorker: DistributedActor where ActorSystem == MySystem {
  distributed func work(name: String) -> String
}

public distributed actor WorkerImpl: RWorker {
  public distributed func work(name: String) -> String {
    return "worked: \(name)"
  }
}

// ==== ----------------------------------------------------------------------
// MARK: A Hub that takes `any RWorker`

public distributed actor Hub {
  // `any RWorker` parameter: the thunk substitutes `$RWorker` over the
  // wire; the receive side decodes a `$RWorker` proxy that is passed
  // (via existential conversion) into the user's body. The inner
  // `worker.work(name:)` call dispatches through the `$RWorker` proxy's
  // distributed thunk back through `remoteCall`, where the actor id
  // routes to the local `WorkerImpl` and `_executeDistributedTarget`
  // recognizes the `$RWorker.work` target identifier
  public distributed func dispatch(to worker: any RWorker) async throws -> String {
    return try await worker.work(name: "world")
  }
}

@main struct Main {
  static func main() async {
    let system = MySystem()
    // Order matters: assignID hands out id=42 first (Hub), then id=7 (Worker)
    _ = Hub(actorSystem: system)
    _ = WorkerImpl(actorSystem: system)

    do {
      let remoteHub = try Hub.resolve(id: MyActorID(id: 42), using: system)
      let remoteWorker = try $RWorker.resolve(id: MyActorID(id: 7), using: system)
      let s = try await remoteHub.dispatch(to: remoteWorker)
      print("[swift] dispatch result: \(s)")
    } catch {
      print("[swift] threw")
    }
  }
}

// CHECK:      [swift] remoteCall reached
// CHECK-NEXT: [swift] remoteCall reached
// CHECK-NEXT: [swift] dispatch result: worked: world
