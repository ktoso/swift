// REQUIRES: swift_swift_parser, asserts
//
// UNSUPPORTED: back_deploy_concurrency
// REQUIRES: concurrency
// REQUIRES: distributed
//
// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems -target %target-swift-6.0-abi-triple %S/../Inputs/FakeDistributedActorSystems.swift
// RUN: %target-swift-frontend -typecheck -target %target-swift-6.0-abi-triple -plugin-path %swift-plugin-dir -parse-as-library -I %t %S/../Inputs/FakeDistributedActorSystems.swift -dump-macro-expansions %s 2>&1 | %FileCheck %s

// Verifies compiler-side attribute inheritance from a distributed protocol
// requirement onto its witness. The user writes `@Entitlement("...")` only
// on the protocol requirement; conformance checking clones the attribute onto
// the concrete witness BEFORE peer macro expansion, so the validation accessor
// for `MyHome.openDoor` is emitted as if the annotation were written there
// directly.
//
// Implementation: `inheritDistributedValidationAttrs` in
// `lib/Sema/TypeCheckDistributed.cpp`, invoked before per-member peer macro
// expansion is triggered.

import Distributed

@available(SwiftStdlib 6.5, *)
protocol HomeAdmin: DistributedActor where ActorSystem == FakeRoundtripActorSystem {
  @Entitlement("com.example.protocol-inherited")
  distributed func openDoor() -> Bool
}

@available(SwiftStdlib 6.5, *)
distributed actor MyHome: HomeAdmin {
  typealias ActorSystem = FakeRoundtripActorSystem

  // No `@Entitlement` on the witness. The compiler clones it from the
  // protocol requirement during conformance checking, before peer macro
  // expansion. The accessor below is emitted as if `@Entitlement` were
  // written here directly, referencing the protocol's entitlement string.
  distributed func openDoor() -> Bool { true }
  // CHECK: #if objectFormat(MachO)
  // CHECK-NEXT: @section("__DATA_CONST,__swift5_davala")
  // CHECK-NEXT: #elseif objectFormat(ELF) || objectFormat(Wasm)
  // CHECK-NEXT: @section("swift5_davala")
  // CHECK-NEXT: #elseif objectFormat(COFF)
  // CHECK-NEXT: @section(".sw5davala$B")
  // CHECK-NEXT: #endif
  // CHECK-NEXT: @used
  // CHECK-NEXT: @available(*, deprecated, message: "Implementation detail of Distributed. Do not use directly.")
  // CHECK-NEXT: private static let $s27FakeDistributedActorSystems6MyHomeC8openDoor11EntitlementfMp_25__daval_openDoor_accessorfMu_: Distributed._DistributedValidationAccessor = { outValue, type, hint, reserved in
  // CHECK-NEXT: let validator: Distributed.RemoteCallValidator = Distributed.RemoteCallValidator({
  // CHECK-NEXT: try Distributed.DistributedValidation.evaluate(Distributed.EntitlementPolicy.entitlement("com.example.protocol-inherited"))
  // CHECK-NEXT: })
  // CHECK-NEXT: outValue.assumingMemoryBound(to: Distributed.RemoteCallValidator.self)
  // CHECK-NEXT: .initialize(to: validator)
  // CHECK-NEXT: return true
  // CHECK-NEXT: }
}
