//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend -target %target-cpu-apple-macos14 -enable-experimental-feature Embedded -parse-as-library %s %S/Inputs/multifile_dispatch_actor.swift -c -o %t/a.o
// RUN: %target-embedded-link %t/a.o %target-embedded-posix-shim -o %t/a.out -L%swift_obj_root/lib/swift/embedded/%module-target-triple %target-clang-resource-dir-opt -lswift_Concurrency -lswiftDistributed %target-swift-default-executor-opt %target-embedded-concurrency-threading-shim -dead_strip
// RUN: %target-run %t/a.out | %FileCheck %s

// Also check the reverse file order: synthesis must not depend on which file
// the frontend happens to type-check first.
// RUN: %target-swift-frontend -target %target-cpu-apple-macos14 -enable-experimental-feature Embedded -parse-as-library %S/Inputs/multifile_dispatch_actor.swift %s -c -o %t/b.o
// RUN: %target-embedded-link %t/b.o %target-embedded-posix-shim -o %t/b.out -L%swift_obj_root/lib/swift/embedded/%module-target-triple %target-clang-resource-dir-opt -lswift_Concurrency -lswiftDistributed %target-swift-default-executor-opt %target-embedded-concurrency-threading-shim -dead_strip
// RUN: %target-run %t/b.out | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: optimized_stdlib
// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// The compiler-synthesized `_executeDistributedTarget` must be visible from a
// file OTHER than the one declaring the `distributed actor`.
//
// `synthesizeEmbeddedDistributedReceiveDispatch` is driven eagerly from
// `TypeChecker::checkDistributedActor`, which runs per-source-file. A reference
// from another file could therefore be resolved before the actor's own file had
// been checked, and sema would report:
//
//   error: value of type 'Greeter' has no member '_executeDistributedTarget'
//
// This is not a corner case: the actor system's `remoteCall` is the natural
// caller of `_executeDistributedTarget`, and a real actor system lives in its
// own file (or its own module-internal file) rather than next to every actor.
// Every other test in this directory is single-file, which is precisely why
// this went unnoticed.
//
// The fix routes synthesis through `NominalTypeDecl::synthesizeSemanticMembers-
// IfNeeded` (see `ImplicitMemberAction::ResolveEmbeddedDistributedReceive-
// Dispatch`), the same lazy-member mechanism `CodingKeys` / `Encodable` /
// `Decodable` use, so the lookup itself triggers the synthesis.
//
// `Greeter` is declared in Inputs/multifile_dispatch_actor.swift.

import _Concurrency
import Distributed

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
  mutating func recordArgument(_ argument: RemoteCallArgument<String>) throws {
    buffer.argString = argument.value
  }
}

struct MyDecoder: DistributedTargetInvocationDecoder {
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

struct MyResultHandler: DistributedTargetInvocationResultHandler {
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
// MARK: The actor system, in a different file from the actor

struct MyActorID: Sendable, Hashable {
  let id: UInt64
}

final class MySystem: DistributedActorSystem, @unchecked Sendable {
  typealias ActorID = MyActorID
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

  func remoteCall<Act>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder
  ) async throws -> InvocationDecoder
      where Act: DistributedActor, Act.ID == ActorID {
    guard let greeter = self.greeter else {
      fatalError("no local greeter registered")
    }
    // This is the cross-file reference under test: `Greeter` is declared in
    // Inputs/multifile_dispatch_actor.swift, and `_executeDistributedTarget`
    // is synthesized onto it by the compiler.
    var decoder = MyDecoder(buffer: buffer)
    let handler = MyResultHandler(buffer: buffer)
    try await greeter._executeDistributedTarget(
        target: target,
        invocationDecoder: &decoder,
        resultHandler: handler)
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

@main struct Main {
  static func main() async {
    let system = MySystem()
    _ = Greeter(actorSystem: system)
    do {
      let remoteRef = try Greeter.resolve(id: MyActorID(id: 42), using: system)
      // Two distinct targets, so the dispatch if-chain is exercised on both
      // the first and a later branch
      print("[swift] hello: \(try await remoteRef.hello(name: "World"))")
      print("[swift] farewell: \(try await remoteRef.farewell(name: "World"))")
    } catch {
      print("[swift] threw")
    }
  }
}

// CHECK: [swift] hello: Hello, World!
// CHECK: [swift] farewell: Goodbye, World!
