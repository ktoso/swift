// REQUIRES: swift_swift_parser, asserts
//
// UNSUPPORTED: back_deploy_concurrency
// REQUIRES: concurrency
// REQUIRES: distributed
//
// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems -target %target-swift-6.0-abi-triple %S/../Inputs/FakeDistributedActorSystems.swift
// RUN: %target-swift-frontend -typecheck -target %target-swift-6.0-abi-triple -plugin-path %swift-plugin-dir -parse-as-library -I %t %S/../Inputs/FakeDistributedActorSystems.swift -dump-macro-expansions %s > %t/expansion.txt 2>&1
// RUN: %FileCheck %s < %t/expansion.txt
// RUN: %FileCheck %s --check-prefix=DEDUP < %t/expansion.txt

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
  distributed func openDoor() -> Bool { true }
}

// The witness has no `@Entitlement`; the compiler clones it from the protocol
// requirement during conformance checking, before peer macro expansion, so
// the accessor below is emitted as if the annotation were written on the
// witness, referencing the protocol's entitlement string.
// CHECK: #if objectFormat(MachO)
// CHECK-NEXT: @section("__DATA_CONST,__swift5_davala")
// CHECK-NEXT: #elseif objectFormat(ELF) || objectFormat(Wasm)
// CHECK-NEXT: @section("swift5_davala")
// CHECK-NEXT: #elseif objectFormat(COFF)
// CHECK-NEXT: @section(".sw5davala$B")
// CHECK-NEXT: #endif
// CHECK-NEXT: @used
// CHECK-NEXT: @available(*, deprecated, message: "Implementation detail of Distributed. Do not use directly.")
// CHECK-NEXT: private static let {{.*}}__daval_openDoor_accessorfMu_: Distributed._DistributedValidationAccessor = { outValue, type, hint, reserved in
// CHECK-NEXT: let expected: Any.Type = Distributed.RemoteCallValidator<MyHome.ActorSystem>.self
// CHECK-NEXT: let requested = type.load(as: Any.Type.self)
// CHECK-NEXT: guard requested == expected else {
// CHECK-NEXT: return false
// CHECK-NEXT: }
// CHECK-NEXT: let validator: Distributed.RemoteCallValidator<MyHome.ActorSystem> = Distributed.RemoteCallValidator<MyHome.ActorSystem>({ _ in
// CHECK-NEXT: try Distributed.DistributedValidation.evaluate(Distributed.EntitlementPolicy.entitlement("com.example.protocol-inherited"))
// CHECK-NEXT: })
// CHECK-NEXT: outValue.assumingMemoryBound(to: Distributed.RemoteCallValidator<MyHome.ActorSystem>.self)
// CHECK-NEXT: .initialize(to: validator)
// CHECK-NEXT: return true
// CHECK-NEXT: }

// Exactly one validation accessor for the single witness - guards the
// attribute-inheritance dedup so a re-clone cannot emit a duplicate accessor.
// DEDUP: __daval_openDoor_accessorfMu
// DEDUP-NOT: accessorfMu
