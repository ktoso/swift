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

// This test exercises the **remote-branch** wire round-trip for a
// `distributed func` that takes a `some/any P` parameter where `P` is a
// `@Resolvable` distributed-actor protocol.
//
// We use a single actor (`GreeterImpl`) that conforms to `Greeter` and also has a
// `sendAnyGreeter(_:)` method. We resolve a `$Greeter` stub for the same
// actor, and a remote `GreeterImpl` proxy. Calling the proxy's `sendAnyGreeter`
// forces the remote-branch encoding (Phase 3 caller side) and the receiver's
// accessor must materialize a `$Greeter` from the wire payload (Phase 4).
//
// Note: `FakeRoundtripActorSystem.assignID` returns the same hardcoded
// `<unique-id>` for every actor, so this test deliberately uses ONE actor.

import Distributed
import FakeDistributedActorSystems

typealias DefaultDistributedActorSystem = FakeRoundtripActorSystem

@Resolvable
protocol Greeter: DistributedActor, Codable
where ActorSystem == FakeRoundtripActorSystem {
  distributed func sayHi() -> String
  distributed func sendAnyGreeter(_ g: any Greeter) async throws -> String
}

distributed actor GreeterImpl: Greeter {
  distributed func sayHi() -> String { "Hi from \(self.id)" }

  distributed func sendAnyGreeter(_ g: any Greeter) async throws -> String {
    print("sendAnyGreeter type: \(type(of: g))")
    return try await g.sayHi()
  }
}

@main
struct Main {
  static func main() async throws {
    let system = FakeRoundtripActorSystem()
    let local = GreeterImpl(actorSystem: system)
    // Resolve a remote reference.
    let proxy = try GreeterImpl.resolve(id: local.id, using: system)

    print("--- any ---")
    let r1 = try await proxy.sendAnyGreeter(local)
    print("result: \(r1)")
    // CHECK: --- any ---
    // CHECK: sendAnyGreeter type: $Greeter
    // CHECK: result: Hi from
  }
}
