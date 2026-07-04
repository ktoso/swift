// REQUIRES: swift_swift_parser, asserts
//
// UNSUPPORTED: back_deploy_concurrency
// REQUIRES: concurrency
// REQUIRES: distributed
//
// RUN: %empty-directory(%t)

// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems -target %target-swift-6.0-abi-triple %S/../Inputs/FakeDistributedActorSystems.swift
// RUN: %target-swift-frontend -typecheck -target %target-swift-6.0-abi-triple -plugin-path %swift-plugin-dir -parse-as-library -I %t %S/../Inputs/FakeDistributedActorSystems.swift -dump-macro-expansions %s 2>&1 | %FileCheck %s

// Verifies the full expanded output of @Entitlement and @ValidateRemoteCall:
// per-object-format section attribute, @used, deprecation marker, section-
// placed static-let record with FourCC 'dval' (0x6476616c), a literal-closure
// accessor that materializes the policy into the out-parameter, and the
// FNV-1a-64 hashes for the actor type and the method name.

import Distributed

@available(SwiftStdlib 6.5, *)
distributed actor MyHome {
  typealias ActorSystem = FakeRoundtripActorSystem

  // FNV-1a-64 hashes emitted by the macro plugin:
  //   fnv1a64("MyHome")     = 0x6260_18f9_9f09_d2c0   (actorTypeID)
  //   fnv1a64("openDoor")   = 0x0c2f_228d_cbee_fc75   (methodID for openDoor)
  //   fnv1a64("openWindow") = 0x67d6_fc23_c6c8_2039   (methodID for openWindow)

  @Entitlement("com.example.openDoor")
  distributed func openDoor() -> Bool { true }
  // CHECK: #if objectFormat(MachO)
  // CHECK-NEXT: @section("__DATA_CONST,__swift5_daval")
  // CHECK-NEXT: #elseif objectFormat(ELF) || objectFormat(Wasm)
  // CHECK-NEXT: @section("swift5_daval")
  // CHECK-NEXT: #elseif objectFormat(COFF)
  // CHECK-NEXT: @section(".sw5daval$B")
  // CHECK-NEXT: #endif
  // CHECK-NEXT: @used
  // CHECK-NEXT: @available(*, deprecated, message: "Implementation detail of Distributed. Do not use directly.")
  // The record name is compiler-issued via `context.makeUniqueName(...)`
  // seeded with `__daval_<method>_record`. This gives each expansion a
  // conflict-free name so stacked or witness+protocol-inherited attributes
  // can coexist on the same declaration. The mangled shape is
  // `$s<module><type><method>{Entitlement|ValidateRemoteCall}fMp_23__daval_<method>_recordfMu_`.
  // CHECK-NEXT: private static let $s27FakeDistributedActorSystems6MyHomeC8openDoor11EntitlementfMp_23__daval_openDoor_recordfMu_: Distributed._DistributedValidationRecord = (
  // CHECK-NEXT: 0x6476616c,
  // CHECK-NEXT: 0,
  // CHECK-NEXT: { outValue, type, hint, reserved in
  // CHECK-NEXT: let validator: Distributed.RemoteCallValidator = Distributed.RemoteCallValidator({
  // CHECK-NEXT: try Distributed.DistributedValidation.evaluate(Distributed.EntitlementPolicy.entitlement("com.example.openDoor"))
  // CHECK-NEXT: })
  // CHECK-NEXT: outValue.assumingMemoryBound(to: Distributed.RemoteCallValidator.self)
  // CHECK-NEXT: .initialize(to: validator)
  // CHECK-NEXT: return true
  // CHECK-NEXT: },
  // CHECK-NEXT: 0x6260_18f9_9f09_d2c0,
  // CHECK-NEXT: 0x0c2f_228d_cbee_fc75
  // CHECK-NEXT: )

  @ValidateRemoteCall({ () throws -> Void in })
  distributed func openWindow() -> Bool { true }
  // CHECK: #if objectFormat(MachO)
  // CHECK-NEXT: @section("__DATA_CONST,__swift5_daval")
  // CHECK-NEXT: #elseif objectFormat(ELF) || objectFormat(Wasm)
  // CHECK-NEXT: @section("swift5_daval")
  // CHECK-NEXT: #elseif objectFormat(COFF)
  // CHECK-NEXT: @section(".sw5daval$B")
  // CHECK-NEXT: #endif
  // CHECK-NEXT: @used
  // CHECK-NEXT: @available(*, deprecated, message: "Implementation detail of Distributed. Do not use directly.")
  // CHECK-NEXT: private static let $s27FakeDistributedActorSystems6MyHomeC10openWindow18ValidateRemoteCallfMp_25__daval_openWindow_recordfMu_: Distributed._DistributedValidationRecord = (
  // CHECK-NEXT: 0x6476616c,
  // CHECK-NEXT: 0,
  // CHECK-NEXT: { outValue, type, hint, reserved in
  // CHECK-NEXT: let validator: Distributed.RemoteCallValidator = Distributed.RemoteCallValidator({ () throws -> Void in
  // CHECK-NEXT: })
  // CHECK-NEXT: outValue.assumingMemoryBound(to: Distributed.RemoteCallValidator.self)
  // CHECK-NEXT: .initialize(to: validator)
  // CHECK-NEXT: return true
  // CHECK-NEXT: },
  // CHECK-NEXT: 0x6260_18f9_9f09_d2c0,
  // CHECK-NEXT: 0x67d6_fc23_c6c8_2039
  // CHECK-NEXT: )
}