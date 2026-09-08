// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend -target %target-cpu-apple-macos14 -enable-experimental-feature Embedded -enable-experimental-feature EmbeddedDistributed -parse-as-library -plugin-path %swift-plugin-dir %s %S/Inputs/ResolvableWorker.swift %S/Inputs/PortableRoundtripActorSystem.swift -c -o %t/a.o
// RUN: %target-embedded-link %t/a.o %target-embedded-posix-shim -o %t/a.out -L%swift_obj_root/lib/swift/embedded/%module-target-triple %target-clang-resource-dir-opt -lswift_Concurrency -lswiftDistributed %target-swift-default-executor-opt %target-embedded-concurrency-threading-shim -dead_strip
// RUN: %target-run %t/a.out | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: optimized_stdlib
// REQUIRES: OS=macosx || OS=wasip1
// REQUIRES: swift_feature_Embedded

// Companion to distributed_embedded_resolvable_any_roundtrip_exec.swift: this
// pins the `some @Resolvable P` parameter support: embedded accepts the same
// `$P`-proxy roundtrip when the parameter is spelled `some ResolvableWorker`
// instead of `any ResolvableWorker`. Everything downstream is identical - the
// type is monomorphized to `$ResolvableWorker` either way, serialized as its
// actor id and resolved back on the receive side.
//
// The actor system lives in the shared
// Inputs/PortableRoundtripActorSystem.swift; `ResolvableWorker` /
// `WorkerImpl` in Inputs/ResolvableWorker.swift.

import _Concurrency
import Distributed

// ==== ----------------------------------------------------------------------
// MARK: A Hub that takes `some ResolvableWorker` (opaque)

public distributed actor Hub {
  // `some ResolvableWorker` parameter: treated exactly like `any ResolvableWorker`
  // in embedded - the thunk substitutes `$ResolvableWorker` over the wire, and the
  // receive side decodes a `$ResolvableWorker` proxy that binds the opaque
  // parameter. No generic substitution is recorded (the embedded encoder has
  // none), because the type is always monomorphized to `$ResolvableWorker`. The
  // inner `worker.work(name:)` call dispatches through the proxy's distributed
  // thunk back through `remoteCall`, where the actor id routes to the local
  // `WorkerImpl`.
  public distributed func dispatch(to worker: some ResolvableWorker) async throws -> String {
    return try await worker.work(name: "world")
  }
}

@main struct Main {
  static func main() async {
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
}

// CHECK:      [swift] remoteCall reached
// CHECK-NEXT: [swift] remoteCall reached
// CHECK-NEXT: [swift] dispatch result: worked: world
