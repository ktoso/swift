// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems %S/../Inputs/FakeDistributedActorSystems.swift
// RUN: %target-build-swift -module-name main -target %target-swift-6.0-abi-triple -plugin-path %swift-plugin-dir -j2 -parse-as-library -I %t %s %S/../Inputs/FakeDistributedActorSystems.swift -o %t/a.out
// RUN: %target-codesign %t/a.out
// RUN: %target-run %t/a.out | %FileCheck %s --dump-input=always
//
// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: distributed
// REQUIRES: swift_swift_parser, asserts
//
// UNSUPPORTED: use_os_stdlib
// UNSUPPORTED: back_deployment_runtime

import Distributed
import FakeDistributedActorSystems

typealias DefaultDistributedActorSystem = FakeRoundtripActorSystem

@Resolvable
protocol Greeter: DistributedActor, Codable
where ActorSystem == FakeRoundtripActorSystem {
  distributed func sayHi() -> String
}

distributed actor RealGreeter: Greeter {
  distributed func sayHi() -> String { "Hi from \(self.id)" }
}

distributed actor Worker {
  distributed func sendAnyGreeter(_ g: any Greeter) async throws -> String {
    print("sendAnyGreeter type: \(type(of: g))")
    return try await g.sayHi()
  }

  distributed func sendSomeGreeter(_ g: some Greeter) async throws -> String {
    print("sendSomeGreeter type: \(type(of: g))")
    return try await g.sayHi()
  }

  distributed func sendGenericGreeter<G: Greeter>(_ g: G) async throws -> String {
    print("sendGenericGreeter type: \(type(of: g))")
    return try await g.sayHi()
  }
}

// This test exercises the local-branch dispatch where the thunk's
// `__isRemoteActor(self)` check returns false and the user function is called
// directly without encoding. `type(of: g)` reflects the original local
// actor (`RealGreeter`), not `$Greeter`, because no resolve happens.
//
// The remote-branch wire round-trip (where the receiver-side decoder would
// observe `$Greeter`) currently crashes because the runtime metadata for the
// param is still the user-declared `any/some Greeter` rather than `$Greeter`.
// That requires Phase 4 IRGen plumbing -- TODO before this can ship.

@main
struct Main {
  static func main() async throws {
    let system = FakeRoundtripActorSystem()

    let real = RealGreeter(actorSystem: system)
    let worker = Worker(actorSystem: system)

    print("--- any ---")
    let r1 = try await worker.sendAnyGreeter(real)
    print("result: \(r1)")
    // CHECK: --- any ---
    // CHECK: sendAnyGreeter type: RealGreeter
    // CHECK: result: Hi from

    print("--- some ---")
    let r2 = try await worker.sendSomeGreeter(real)
    print("result: \(r2)")
    // CHECK: --- some ---
    // CHECK: sendSomeGreeter type: RealGreeter
    // CHECK: result: Hi from

    print("--- generic ---")
    let r3 = try await worker.sendGenericGreeter(real)
    print("result: \(r3)")
    // CHECK: --- generic ---
    // CHECK: sendGenericGreeter type: RealGreeter
    // CHECK: result: Hi from
  }
}
