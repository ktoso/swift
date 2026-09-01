// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend -target %target-cpu-apple-macos14 -enable-experimental-feature Embedded -enable-experimental-feature EmbeddedDistributed -parse-as-library %s -c -o %t/a.o
// RUN: %target-embedded-link %t/a.o %target-embedded-posix-shim -o %t/a.out -L%swift_obj_root/lib/swift/embedded/%module-target-triple %target-clang-resource-dir-opt -lswift_Concurrency -lswiftDistributed %target-swift-default-executor-opt %target-embedded-concurrency-threading-shim -dead_strip
// RUN: %target-run %t/a.out | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: optimized_stdlib
// REQUIRES: OS=macosx || OS=wasip1
// REQUIRES: swift_feature_Embedded

// End-to-end round-trip that exercises the COMPILER-SYNTHESIZED
// `_executeDistributedTarget` instance method on the distributed actor.
//
// On the receiver side, the actor system's `remoteCall` does:
//   try await self.greeter._executeDistributedTarget(
//       target: target, invocationDecoder: &decoder, resultHandler: handler)
//
// The compiler synthesizes that method's body, which:
//   1. compares `target.identifier` against each distributed func's
//      mangled-thunk name;
//   2. decodes args via `decoder.decodeNextArgument(T.self)`;
//   3. calls the local impl;
//   4. hands the result to `handler.onReturn(_:)` / `onReturnVoid()`.
//
// No hand-written switch on the user side.

import _Concurrency
import Distributed

// ==== ----------------------------------------------------------------------
// MARK: The system's serialization requirement
//
// The concrete system binds `SerializationRequirement` to its own protocol and
// conforming types serialize through a single generic member on the encoder /
// decoder / handler rather than per-type overloads. This test only moves
// `String`, so that is all that conforms.

protocol MySerializationRequirement {
  func encoded() -> String
  static func decode(_ s: String) -> Self
}
extension String: MySerializationRequirement {
  func encoded() -> String { self }
  static func decode(_ s: String) -> String { s }
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

  var greeter: Greeter?
  let buffer = CallBuffer()

  init() {}

  func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
      where Act: DistributedActor, Act.ID == ActorID {
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

  func remoteCall<Act, Res>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder
  ) async throws -> Res
      where Act: DistributedActor, Act.ID == ActorID, Res: MySerializationRequirement {
    print("[swift] remoteCall reached")
    guard let greeter = self.greeter else {
      fatalError("no local greeter registered")
    }
    // Receiver-side dispatch via the compiler-synthesized method.
    var decoder = MyDecoder(buffer: buffer)
    let handler = MyResultHandler(buffer: buffer)
    try await greeter._executeDistributedTarget(
        target: target,
        invocationDecoder: &decoder,
        resultHandler: handler)
    // The handler stashed the serialized result; decode it into `Res` here.
    // Moving this decode into the system is what lets the synthesized thunk
    // just return remoteCall's result directly.
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

distributed actor Greeter {
  distributed func hello(name: String) -> String {
    return "Hello, \(name)!"
  }
}

@main struct Main {
  static func main() async {
    let system = MySystem()
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
