// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend -target %target-cpu-apple-macos14 -enable-experimental-feature Embedded -parse-as-library %s -c -o %t/a.o
// RUN: %target-embedded-link %t/a.o %target-embedded-posix-shim -o %t/a.out -L%swift_obj_root/lib/swift/embedded/%module-target-triple %target-clang-resource-dir-opt -lswift_Concurrency -lswiftDistributed %target-swift-default-executor-opt %target-embedded-concurrency-threading-shim -dead_strip
// RUN: %target-run %t/a.out | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: optimized_stdlib
// REQUIRES: OS=macosx || OS=wasip1
// REQUIRES: swift_feature_Embedded

// End-to-end round-trip for a distributed actor under Embedded:
//   1. Build a "remote" reference via Greeter.resolve(id:using:) - that
//      goes through swift_distributedActor_remote_initialize.
//   2. Call the distributed func on it; the synthesized thunk takes the
//      remote branch (swift_distributed_actor_is_remote() returns true).
//   3. The thunk calls system.remoteCall(on:target:invocation:), which
//      in this stub system synchronously invokes the LOCAL greeter
//      (kept on the side) and stashes the result in the call buffer.
//   4. The thunk decodes the result via decoder.decodeNextArgument and
//      returns it to the caller.

import _Concurrency
import Distributed

// ==== ----------------------------------------------------------------------
// MARK: A tiny in-memory transport (single-process)

final class CallBuffer {
  var argString: String?
  var returnString: String?

  init() {}
}

// ==== ----------------------------------------------------------------------
// MARK: Encoder / Decoder / ResultHandler

struct MyEncoder: EmbeddedDistributedTargetInvocationEncoder {
  let buffer: CallBuffer
  init(buffer: CallBuffer) { self.buffer = buffer }

  mutating func doneRecording() throws {}
}
extension MyEncoder {
  mutating func recordArgument(_ argument: RemoteCallArgument<String>) throws {
    buffer.argString = argument.value
  }
  mutating func recordReturnType(_ type: String.Type) throws {}
}

struct MyDecoder: EmbeddedDistributedTargetInvocationDecoder {
  let buffer: CallBuffer
  init(buffer: CallBuffer) { self.buffer = buffer }
}
extension MyDecoder {
  mutating func decodeNextArgument(_ type: String.Type) throws -> String {
    guard let v = buffer.argString else { fatalError("missing arg") }
    buffer.argString = nil
    return v
  }
}

struct MyResultHandler: EmbeddedDistributedTargetInvocationResultHandler {
  let buffer: CallBuffer
  init(buffer: CallBuffer) { self.buffer = buffer }

  func onReturnVoid() async throws {}
  func onThrow(error: any Error) async throws {
    fatalError("threw in handler")
  }
}
extension MyResultHandler {
  func onReturn(_ value: String) async throws {
    buffer.returnString = value
  }
}

// ==== ----------------------------------------------------------------------
// MARK: The actor system

struct MyActorID: Sendable, Hashable {
  let id: UInt64
}

final class MySystem: EmbeddedDistributedActorSystem, @unchecked Sendable {
  typealias ActorID = MyActorID
  typealias InvocationEncoder = MyEncoder
  typealias InvocationDecoder = MyDecoder
  typealias ResultHandler = MyResultHandler

  // Single in-process "registry": at most one Greeter at the well-known
  // id we use for the round-trip. A real system maintains an
  // ActorID -> DistributedActor map.
  var greeter: Greeter?
  let buffer = CallBuffer()

  init() {}

  func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
      where Act: DistributedActor, Act.ID == ActorID {
    // Return nil so the Swift runtime constructs a remote proxy. The
    // proxy's distributed-func calls go through remoteCall below.
    return nil
  }
  func assignID<Act>(_ actorType: Act.Type) -> ActorID
      where Act: DistributedActor, Act.ID == ActorID {
    return MyActorID(id: 42)
  }
  func actorReady<Act>(_ actor: Act)
      where Act: DistributedActor, Act.ID == ActorID {
    if let g = actor as? Greeter {
      self.greeter = g
    }
  }
  func resignID(_ id: ActorID) {}

  func makeInvocationEncoder() -> InvocationEncoder {
    .init(buffer: buffer)
  }

  func remoteCall<Act>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder
  ) async throws -> InvocationDecoder
      where Act: DistributedActor, Act.ID == ActorID {
    print("[swift] remoteCall reached")
    guard let greeter = self.greeter else {
      fatalError("no local greeter registered")
    }
    // Receiver-side dispatch via the compiler-synthesized
    // `_executeDistributedTarget` method on the local actor. The
    // synthesized body matches `target.identifier` against each
    // distributed func, decodes the args via our per-type decoder
    // overloads, calls the impl, and hands the result back through
    // the result handler.
    var decoder = MyDecoder(buffer: buffer)
    let handler = MyResultHandler(buffer: buffer)
    try await greeter._executeDistributedTarget(
        target: target,
        invocationDecoder: &decoder,
        resultHandler: handler)
    // The handler stashed the typed result in returnString; expose
    // it via a fresh decoder for the sender-side thunk to pick up.
    buffer.argString = buffer.returnString
    buffer.returnString = nil
    return MyDecoder(buffer: buffer)
  }

  func remoteCallVoid<Act>(
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
// MARK: The actor under test

distributed actor Greeter {
  distributed func hello(name: String) -> String {
    return "Hello, \(name)!"
  }
}

@main struct Main {
  static func main() async {
    let system = MySystem()
    // Local greeter the system can dispatch to when it gets a "remote" call.
    _ = Greeter(actorSystem: system)

    do {
      let remoteRef = try Greeter.resolve(id: MyActorID(id: 42), using: system)
      let result = try await remoteRef.hello(name: "World")
      print("[swift] result: \(result)")
    } catch {
      print("[swift] threw")
    }
  }
}

// CHECK: [swift] remoteCall reached
// CHECK: [swift] result: Hello, World!
