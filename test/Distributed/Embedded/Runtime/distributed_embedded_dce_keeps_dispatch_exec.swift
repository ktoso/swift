// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend -target %target-cpu-apple-macos14 -O -wmo -enable-experimental-feature Embedded -enable-experimental-feature EmbeddedDistributed -parse-as-library %s -c -o %t/a.o
// RUN: %target-embedded-link %t/a.o %target-embedded-posix-shim -o %t/a.out -L%swift_obj_root/lib/swift/embedded/%module-target-triple %target-clang-resource-dir-opt -lswift_Concurrency -lswiftDistributed %target-swift-default-executor-opt %target-embedded-concurrency-threading-shim -dead_strip
// RUN: %target-run %t/a.out | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: optimized_stdlib
// REQUIRES: OS=macosx || OS=wasip1
// REQUIRES: swift_feature_Embedded

// Regression test: dead-code elimination must NOT remove the code needed
// to invoke a distributed func.
//
// The impl of a `distributed func` is reachable only through the
// compiler-synthesized `_executeDistributedTarget`, which resolves the
// callee at runtime by string-comparing `target.identifier` against each
// func's mangled distributed-thunk name. There is no statically-visible
// typed call edge from user code to the impl: the sender side only ever
// calls the actor system's `remoteCall`, and `remoteCall` dispatches by
// that runtime string.
//
// This makes the impl (and the arg-decode / result-handler machinery it
// pulls in) a DCE liability: an over-aggressive SIL DCE or linker
// `-dead_strip` could keep the name comparison while stripping the body,
// so dispatch would "succeed" at matching but crash or no-op on the call.
//
// To make that failure mode observable, we build with `-O -wmo` (SIL DCE
// on) and link with `-dead_strip`, then assert the func BODY actually ran
// (its marker print) and produced the right value (2 * 21 == 42), decoded
// through `decodeNextArgument` and delivered through `onReturn`.

import _Concurrency
import Distributed

// ==== ----------------------------------------------------------------------
// MARK: The system's serialization requirement
//
// The concrete system binds `SerializationRequirement` to its own protocol and
// conforming types serialize through a single generic member on the encoder /
// decoder / handler rather than per-type overloads. This test only moves `Int`,
// so that is all that conforms.

protocol MySerializationRequirement {
  func encoded() -> String
  static func decode(_ s: String) -> Self
}
extension Int: MySerializationRequirement {
  func encoded() -> String { String(self) }
  static func decode(_ s: String) -> Int { Int(s)! }
}

// ==== ----------------------------------------------------------------------
// MARK: A tiny in-memory transport

final class CallBuffer {
  var argString: String?
  var returnString: String?
  init() {}
}

// ==== ----------------------------------------------------------------------
// MARK: Encoder / Decoder / ResultHandler

struct MyEncoder: DistributedTargetInvocationEncoder {
  let buffer: CallBuffer
  init(buffer: CallBuffer) { self.buffer = buffer }
  mutating func doneRecording() throws {}
}
extension MyEncoder {
  mutating func recordArgument<Value: MySerializationRequirement>(
      _ argument: RemoteCallArgument<Value>) throws {
    buffer.argString = argument.value.encoded()
  }
}

struct MyDecoder: DistributedTargetInvocationDecoder {
  let buffer: CallBuffer
  init(buffer: CallBuffer) { self.buffer = buffer }
}
extension MyDecoder {
  mutating func decodeNextArgument<Argument: MySerializationRequirement>() throws -> Argument {
    guard let v = buffer.argString else { fatalError("missing arg") }
    buffer.argString = nil
    return Argument.decode(v)
  }
}

struct MyResultHandler: DistributedTargetInvocationResultHandler {
  let buffer: CallBuffer
  init(buffer: CallBuffer) { self.buffer = buffer }
  func onReturnVoid() async throws {}
  func onThrow(error: any Error) async throws {
    fatalError("threw in handler")
  }
}
extension MyResultHandler {
  func onReturn<Success: MySerializationRequirement>(_ value: Success) async throws {
    buffer.returnString = value.encoded()
  }
}

// ==== ----------------------------------------------------------------------
// MARK: The actor system

struct MyActorID: Sendable, Hashable {
  let id: UInt64
}

final class MySystem: DistributedActorSystem, @unchecked Sendable {
  typealias ActorID = MyActorID
  typealias SerializationRequirement = MySerializationRequirement
  typealias InvocationEncoder = MyEncoder
  typealias InvocationDecoder = MyDecoder
  typealias ResultHandler = MyResultHandler

  var worker: Worker?
  let buffer = CallBuffer()

  init() {}

  func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
      where Act: DistributedActor, Act.ID == ActorID {
    return nil
  }
  func assignID<Act>(_ actorType: Act.Type) -> ActorID
      where Act: DistributedActor, Act.ID == ActorID {
    return MyActorID(id: 7)
  }
  func actorReady<Act>(_ actor: Act)
      where Act: DistributedActor, Act.ID == ActorID {
    if let w = actor as? Worker {
      self.worker = w
    }
  }
  func resignID(_ id: ActorID) {}

  func makeInvocationEncoder() -> InvocationEncoder {
    .init(buffer: buffer)
  }

  func remoteCall<Act, Res>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder
  ) async throws -> Res
      where Act: DistributedActor, Act.ID == ActorID, Res: MySerializationRequirement {
    guard let worker = self.worker else {
      fatalError("no local worker registered")
    }
    // Dispatch happens purely by `target.identifier` (a runtime string)
    // inside the compiler-synthesized method - no typed edge to the impl
    var decoder = MyDecoder(buffer: buffer)
    let handler = MyResultHandler(buffer: buffer)
    try await worker._executeDistributedTarget(
        target: target,
        invocationDecoder: &decoder,
        resultHandler: handler)
    // The handler stashed the serialized result; decode it into `Res` here so
    // the synthesized thunk can just return remoteCall's result directly
    guard let raw = buffer.returnString else {
      fatalError("no result recorded")
    }
    buffer.returnString = nil
    return Res.decode(raw)
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

distributed actor Worker {
  distributed func compute(_ x: Int) -> Int {
    // This marker proves the impl BODY survived DCE / -dead_strip, not just
    // that the mangled-name comparison matched.
    print("[swift] compute impl ran")
    return x * 2
  }
}

@main struct Main {
  static func main() async {
    let system = MySystem()
    _ = Worker(actorSystem: system)
    do {
      let remoteRef = try Worker.resolve(id: MyActorID(id: 7), using: system)
      let result = try await remoteRef.compute(21)
      print("[swift] result: \(result)")
    } catch {
      print("[swift] threw")
    }
  }
}

// CHECK: [swift] compute impl ran
// CHECK: [swift] result: 42
