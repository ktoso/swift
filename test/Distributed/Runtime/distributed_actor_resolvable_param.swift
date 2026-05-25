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
    try await g.sayHi()
  }

  distributed func sendSomeGreeter(_ g: some Greeter) async throws -> String {
    try await g.sayHi()
  }
}

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
    // CHECK: result: Hi from

    print("--- some ---")
    let r2 = try await worker.sendSomeGreeter(real)
    print("result: \(r2)")
    // CHECK: --- some ---
    // CHECK: result: Hi from
  }
}
