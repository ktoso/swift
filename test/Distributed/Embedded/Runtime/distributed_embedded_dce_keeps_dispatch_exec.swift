// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend -target %target-cpu-apple-macos14 -O -wmo -enable-experimental-feature Embedded -enable-experimental-feature EmbeddedDistributed -parse-as-library %s %S/Inputs/EmbeddedFakeActorSystem.swift -c -o %t/a.o
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
// through `decodeNextArgument` and delivered through `onReturn`. The actor
// system lives in the shared Inputs/EmbeddedFakeActorSystem.swift.

import _Concurrency
import Distributed

typealias DefaultDistributedActorSystem = EmbeddedFakeRoundtripActorSystem

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
    let system = EmbeddedFakeRoundtripActorSystem()
    let local = Worker(actorSystem: system)
    do {
      let remoteRef = try Worker.resolve(id: local.id, using: system)
      let result = try await remoteRef.compute(21)
      print("[swift] result: \(result)")
    } catch {
      print("[swift] threw")
    }
  }
}

// CHECK: [swift] compute impl ran
// CHECK: [swift] result: 42
