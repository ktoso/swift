// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems %S/../Inputs/FakeDistributedActorSystems.swift
// RUN: %target-build-swift -module-name main -Xfrontend -disable-availability-checking -j2 -parse-as-library -I %t %s %S/../Inputs/FakeDistributedActorSystems.swift -emit-silgen 2>&1 | %FileCheck %s --dump-input=always
// NEIN: %target-codesign %t/a.out
// NEIN: %target-run %t/a.out | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: distributed

// rdar://76038845
// UNSUPPORTED: use_os_stdlib
// UNSUPPORTED: back_deployment_runtime

// FIXME(distributed): Distributed actors currently have some issues on windows rdar://82593574
// UNSUPPORTED: OS=windows-msvc
// https://github.com/apple/swift/issues/65529
// UNSUPPORTED: single_threaded_concurrency


import Distributed
import FakeDistributedActorSystems

typealias DefaultDistributedActorSystem = FakeRoundtripActorSystem

@Resolvable
protocol TestProtocol: DistributedActor where ActorSystem == FakeRoundtripActorSystem {
    distributed func coolFunction() -> Int
    distributed var coolValue: Int { get throws }
}

distributed actor Dummy: TestProtocol {
    distributed func coolFunction() -> Int { 0 }
    distributed var coolValue: Int {
        0
    }
}

// CHECK: // function_ref TestProtocol<>.coolFunction()
// CHECK:   %30 = function_ref @$s4main12TestProtocolPAA11Distributed01_D9ActorStubRzrlE12coolFunctionSiyYaKFTE : $@convention(method) @async <τ_0_0 where τ_0_0 : _DistributedActorStub, τ_0_0 : TestProtocol> (@guaranteed τ_0_0) -> (Int, @error any Error) // user: %32
// CHECK:   hop_to_executor %29 // id: %31
// CHECK:   try_apply %30<$TestProtocol>(%29) : $@convention(method) @async <τ_0_0 where τ_0_0 : _DistributedActorStub, τ_0_0 : TestProtocol> (@guaranteed τ_0_0) -> (Int, @error any Error), normal bb2, error bb5 // id: %32

// CHECK-NOT:   try_apply undef<$TestProtocol>(%37) : $@convention(method) @async <τ_0_0 where τ_0_0 : _DistributedActorStub, τ_0_0 : TestProtocol> (@sil_isolated @guaranteed τ_0_0) -> (Int, @error any Error), normal bb3, error bb6 // id: %39

func setup() async throws {
    let system = FakeRoundtripActorSystem()
    let dummy = Dummy(actorSystem: system)
    let stub = try $TestProtocol.resolve(id: dummy.id, using: system)
    try await setup(stub: stub)
}
func setup(stub: $TestProtocol) async throws {
    _ = try await stub.coolFunction()
    _ = try await stub.coolValue
}

@main struct Main {
  static func main() async {
     try! await setup()
  }
}
