// RUN: %empty-directory(%t)
// RUN: %target-build-swift -module-name main -j2 -parse-as-library -I %t %s -plugin-path %swift-plugin-dir -o %t/a.out
// RUN: %target-codesign %t/a.out
// RUN: %target-run %t/a.out | %FileCheck %s --color

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: distributed

// rdar://76038845
// UNSUPPORTED: use_os_stdlib
// UNSUPPORTED: back_deployment_runtime

// rdar://90373022
// UNSUPPORTED: OS=watchos

// FIXME: pending fixes about thunk bodies in extensions
//   ld: Undefined symbols:
//    _$s4main14WorkerProtocolPAA11Distributed01_D9ActorStubRzrlE19distributedVariableSSyYaKFTE, referenced from:
//        _$s4main15$WorkerProtocolCAA0bC0A2aDP19distributedVariableSSvgTWTE in distributed_actor_localSystem_distributedProtocol-143279.o
//    _$s4main14WorkerProtocolPAA11Distributed01_D9ActorStubRzrlE19distributedVariableSSyYaKFTETu, referenced from:
//        _$s4main15$WorkerProtocolCAA0bC0A2aDP19distributedVariableSSvgTWTE in distributed_actor_localSystem_distributedProtocol-143279.o

import Distributed

@_DistributedProtocol
@available(SwiftStdlib 6.0, *)
protocol WorkerProtocol: DistributedActor where ActorSystem == LocalTestingDistributedActorSystem {
  distributed func distributedMethod() -> String
//  distributed var distributedVariable: String { get }
//  distributed func genericMethod<E: Codable>(_ value: E) async -> E
}

@available(SwiftStdlib 6.0, *)
distributed actor Worker: WorkerProtocol {
  distributed func distributedMethod() -> String {
    "implemented method"
  }

//  distributed var distributedVariable: String {
//    "implemented variable"
//  }

//  distributed func genericMethod<E: Codable>(_ value: E) async -> E {
//    return value
//  }
}

// ==== Execute ----------------------------------------------------------------


//@available(SwiftStdlib 6.0, *)
//func test_distributedVariable<DA: WorkerProtocol>(actor: DA) async throws -> String {
//  try await actor.distributedVariable
//}

@available(SwiftStdlib 6.0, *)
@main struct Main {
  static func main() async throws {
    let system = LocalTestingDistributedActorSystem()

    let actor: any WorkerProtocol = Worker(actorSystem: system)

    let m = try await actor.distributedMethod()
    print("m = \(m)") // CHECK: m = implemented method

//    // force a call through witness table
//    let v1 = try await test_distributedVariable(actor: actor)
//    print("v1 = \(v1)") // CHECK: v1 = implemented!

//    let v = try await actor.distributedVariable
//    print("v = \(v)") // CHECK: v = implemented variable
  }
}
