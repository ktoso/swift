// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend -target %target-cpu-apple-macos14 -enable-experimental-feature Embedded -enable-experimental-feature EmbeddedDistributed -parse-as-library %s %S/Inputs/EmbeddedFakeActorSystem.swift -c -o %t/a.o
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
//   try await <local actor>._executeDistributedTarget(
//       target: target, invocationDecoder: &decoder, resultHandler: handler)
//
// The compiler synthesizes that method's body, which:
//   1. compares `target.identifier` against each distributed func's
//      mangled-thunk name;
//   2. decodes args via `decoder.decodeNextArgument(T.self)`;
//   3. calls the local impl;
//   4. hands the result to `handler.onReturn(_:)` / `onReturnVoid()`.
//
// No hand-written switch on the user side. The actor system that drives this
// lives in the shared Inputs/EmbeddedFakeActorSystem.swift.

import _Concurrency
import Distributed

typealias DefaultDistributedActorSystem = EmbeddedFakeRoundtripActorSystem

distributed actor Greeter {
  distributed func hello(name: String) -> String {
    return "Hello, \(name)!"
  }
}

@main struct Main {
  static func main() async {
    let system = EmbeddedFakeRoundtripActorSystem()
    let local = Greeter(actorSystem: system)
    do {
      let remoteRef = try Greeter.resolve(id: local.id, using: system)
      let result = try await remoteRef.hello(name: "World")
      print("[swift] result: \(result)")
    } catch {
      print("[swift] threw")
    }
  }
}

// CHECK: [swift] remoteCall reached
// CHECK: [swift] result: Hello, World!
