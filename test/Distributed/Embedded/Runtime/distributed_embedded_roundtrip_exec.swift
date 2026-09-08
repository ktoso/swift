// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend -target %target-cpu-apple-macos14 -enable-experimental-feature Embedded -enable-experimental-feature EmbeddedDistributed -parse-as-library -plugin-path %swift-plugin-dir %s %S/Inputs/ResolvableWorker.swift %S/Inputs/PortableRoundtripActorSystem.swift -c -o %t/a.o
// RUN: %target-embedded-link %t/a.o %target-embedded-posix-shim -o %t/a.out -L%swift_obj_root/lib/swift/embedded/%module-target-triple %target-clang-resource-dir-opt -lswift_Concurrency -lswiftDistributed %target-swift-default-executor-opt %target-embedded-concurrency-threading-shim -dead_strip
// RUN: %target-run %t/a.out | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: optimized_stdlib
// REQUIRES: OS=macosx || OS=wasip1
// REQUIRES: swift_feature_Embedded

// End-to-end distributed round-trips under Embedded, over a real serialized byte
// wire (the actor system lives in Inputs/PortableRoundtripActorSystem.swift; the
// `@Resolvable` types in Inputs/ResolvableWorker.swift). Each case is its own
// `test_` method so it can be run / inspected individually.
//
//  - test_roundtrip: resolve a remote proxy, call a `distributed func`; the
//    argument and result cross as bytes and come back decoded.
//  - test_resolvableAny: pass a distributed-actor REFERENCE (`any ResolvableWorker`,
//    i.e. the `$ResolvableWorker` proxy) as an argument; it is serialized as its
//    id and resolved back into a proxy on the receive side, whose `work(...)`
//    re-enters `remoteCall` and routes by id to the hosted `WorkerImpl`.

import _Concurrency
import Distributed

// Uses the default system (PortableRoundtripActorSystem).
distributed actor Greeter {
  distributed func hello(name: String) -> String {
    return "Hello, \(name)!"
  }
}

// A Hub taking `any ResolvableWorker` (ResolvableWorker / WorkerImpl live in
// Inputs/ResolvableWorker.swift).
distributed actor Hub {
  distributed func dispatch(to worker: any ResolvableWorker) async throws -> String {
    return try await worker.work(name: "world")
  }
}

func test_roundtrip() async {
  print("[swift] test_roundtrip")
  let system = PortableRoundtripActorSystem()
  // Local greeter the system can dispatch to when it gets a "remote" call.
  let local = Greeter(actorSystem: system)
  do {
    let remoteRef = try Greeter.resolve(id: local.id, using: system)
    let result = try await remoteRef.hello(name: "World")
    print("[swift] result: \(result)")
  } catch {
    print("[swift] threw")
  }
}

func test_resolvableAny() async {
  print("[swift] test_resolvableAny")
  let system = PortableRoundtripActorSystem()
  let hub = Hub(actorSystem: system)
  let worker = WorkerImpl(actorSystem: system)
  do {
    let remoteHub = try Hub.resolve(id: hub.id, using: system)
    let remoteWorker = try $ResolvableWorker.resolve(id: worker.id, using: system)
    let s = try await remoteHub.dispatch(to: remoteWorker)
    print("[swift] dispatch result: \(s)")
  } catch {
    print("[swift] threw")
  }
}

@main struct Main {
  static func main() async {
    await test_roundtrip()
    await test_resolvableAny()
  }
}

// CHECK-LABEL: [swift] test_roundtrip
// CHECK: [swift] remoteCall reached
// CHECK: [swift] result: Hello, World!

// CHECK-LABEL: [swift] test_resolvableAny
// CHECK:      [swift] remoteCall reached
// CHECK-NEXT: [swift] remoteCall reached
// CHECK-NEXT: [swift] dispatch result: worked: world
