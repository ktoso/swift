// REQUIRES: swift_swift_parser, asserts
//
// UNSUPPORTED: back_deploy_concurrency
// REQUIRES: concurrency
// REQUIRES: distributed
//
// End-to-end cross-module test via `.swiftinterface` rebuild: `@Entitlement`
// on a distributed protocol requirement in module `HomeAdminAPI`. The
// producer emits both `.swiftmodule` and `.swiftinterface`. We then delete
// the `.swiftmodule` before the client build so the compiler drives the
// `ModuleInterfaceBuilder` path, and the client must reconstruct the
// requirement's `@Entitlement("...")` `CustomAttr` from the interface. The
// witness on the conforming actor inherits it via source-buffer synthesis
// in `inheritDistributedValidationAttrs` and the peer macro emits the
// `__daval_*_record` on the witness.
//
// RUN: %empty-directory(%t)
// RUN: %empty-directory(%t/ModuleCache)
//
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems -target %target-swift-6.0-abi-triple %S/../Inputs/FakeDistributedActorSystems.swift
//
// Producer: emit BOTH the .swiftmodule and the .swiftinterface, then remove
// the .swiftmodule so the client must go through the interface.
// RUN: %target-swift-frontend -emit-module -emit-module-path %t/HomeAdminAPI.swiftmodule -emit-module-interface-path %t/HomeAdminAPI.swiftinterface -module-name HomeAdminAPI -target %target-swift-6.0-abi-triple -plugin-path %swift-plugin-dir -parse-as-library -enable-library-evolution -I %t %S/Inputs/HomeAdminAPI.swift
// RUN: rm %t/HomeAdminAPI.swiftmodule
//
// Consumer: force the interface path via -module-cache-path pointing at an
// empty dir. Should transparently invoke ModuleInterfaceBuilder, cache an
// intermediate .swiftmodule, load it.
// RUN: %target-swift-frontend -typecheck -target %target-swift-6.0-abi-triple -plugin-path %swift-plugin-dir -parse-as-library -I %t -module-cache-path %t/ModuleCache -dump-macro-expansions %s 2>&1 | %FileCheck %s

import Distributed
import FakeDistributedActorSystems
import HomeAdminAPI

@available(SwiftStdlib 6.5, *)
distributed actor MyHome: HomeAdmin {
  typealias ActorSystem = FakeRoundtripActorSystem

  // Witness has no attribute; the compiler inherits `@Entitlement` from the
  // (imported, deserialized-from-interface-rebuild) protocol requirement.
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
  // CHECK-NEXT: private static let __daval_openDoor_record: Distributed._DistributedValidationRecord = (
  // CHECK-NEXT: 0x6476616c,
  // CHECK-NEXT: 0,
  // CHECK-NEXT: { outValue, type, hint, reserved in
  // CHECK-NEXT: let validator: Distributed.RemoteCallValidator = Distributed.RemoteCallValidator({
  // CHECK-NEXT: try Distributed._DistributedValidation.evaluate(Distributed._EntitlementPolicy.entitlement("com.example.cross-module"))
  // CHECK-NEXT: })
}
