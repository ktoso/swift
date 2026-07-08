// REQUIRES: swift_swift_parser, asserts
//
// UNSUPPORTED: back_deploy_concurrency
// REQUIRES: concurrency
// REQUIRES: distributed
//
// End-to-end cross-module test via `.swiftinterface` rebuild: `@Entitlement`
// on a distributed protocol requirement in module `AdminProtocol`. The
// producer emits both `.swiftmodule` and `.swiftinterface`. We then delete
// the `.swiftmodule` before the client build so the compiler drives the
// `ModuleInterfaceBuilder` path, and the client must reconstruct the
// requirement's `@Entitlement("...")` `CustomAttr` from the interface. The
// witness on the conforming actor inherits it via source-buffer synthesis
// in `inheritDistributedValidationAttrs` and the peer macro emits the
// validation accessor on the witness.
//
// RUN: %empty-directory(%t)
// RUN: %empty-directory(%t/ModuleCache)
//
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems -target %target-swift-6.0-abi-triple %S/../Inputs/FakeDistributedActorSystems.swift
//
// Producer: emit BOTH the .swiftmodule and the .swiftinterface, then remove
// the .swiftmodule so the client must go through the interface.
// RUN: %target-swift-frontend -emit-module -emit-module-path %t/AdminProtocol.swiftmodule -emit-module-interface-path %t/AdminProtocol.swiftinterface -module-name AdminProtocol -target %target-swift-6.0-abi-triple -plugin-path %swift-plugin-dir -parse-as-library -enable-library-evolution -I %t %S/Inputs/AdminProtocol.swift
// RUN: rm %t/AdminProtocol.swiftmodule
//
// Consumer: force the interface path via -module-cache-path pointing at an
// empty dir. Should transparently invoke ModuleInterfaceBuilder, cache an
// intermediate .swiftmodule, load it.
// RUN: %target-swift-frontend -typecheck -target %target-swift-6.0-abi-triple -plugin-path %swift-plugin-dir -parse-as-library -I %t -module-cache-path %t/ModuleCache -dump-macro-expansions %s 2>&1 | %FileCheck %s

import Distributed
import FakeDistributedActorSystems
import AdminProtocol

@available(SwiftStdlib 6.5, *)
distributed actor MyHome: HomeAdmin {
  typealias ActorSystem = FakeRoundtripActorSystem

  // Witness has no attribute; the compiler inherits `@Entitlement` from the
  // (imported, deserialized-from-interface-rebuild) protocol requirement.
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
  // CHECK-NEXT: private static let $s51distributed_macro_validation_cross_module_interface6MyHomeC8openDoor11EntitlementfMp_25__daval_openDoor_accessorfMu_: Distributed._DistributedValidationAccessor = { outValue, type, hint, reserved in
  // CHECK-NEXT: let expected: Any.Type = Distributed.RemoteCallValidator<MyHome.ActorSystem>.self
  // CHECK-NEXT: let requested = type.load(as: Any.Type.self)
  // CHECK-NEXT: guard requested == expected else {
  // CHECK-NEXT: return false
  // CHECK-NEXT: }
  // CHECK-NEXT: let validator: Distributed.RemoteCallValidator<MyHome.ActorSystem> = Distributed.RemoteCallValidator<MyHome.ActorSystem>({ _ in
  // CHECK-NEXT: try Distributed.DistributedValidation.evaluate(Distributed.EntitlementPolicy.entitlement("com.example.cross-module"))
  // CHECK-NEXT: })

  // Composite policy inherited across the interface-rebuild boundary. The
  // interface printer normalizes module references to the `Module::Type`
  // module-selector syntax, so the arg text preserved through the
  // interface rebuild is the qualified form (unlike the direct
  // `.swiftmodule` path, which keeps the user's original source text).
  distributed func openDoorAnyOf() -> Bool { true }
  // CHECK: private static let $s51distributed_macro_validation_cross_module_interface6MyHomeC13openDoorAnyOf11EntitlementfMp_30__daval_openDoorAnyOf_accessorfMu_: Distributed._DistributedValidationAccessor = { outValue, type, hint, reserved in
  // CHECK: try Distributed.DistributedValidation.evaluate((Distributed::EntitlementPolicy.anyOf([Distributed::EntitlementPolicy.entitlement("com.example.cross-module"), Distributed::EntitlementPolicy.entitlement("com.example.admin")])) as Distributed.EntitlementPolicy)

  // Short-form composite policy inherited across the interface-rebuild
  // boundary. In the source module the user wrote a bare `.anyOf([...])`
  // with no explicit type prefix. The interface printer resolves the
  // implicit-member syntax against the macro parameter type at print time
  // and emits the fully-qualified form (`Distributed::EntitlementPolicy.
  // anyOf([Distributed::EntitlementPolicy.entitlement(...), ...])`), which
  // the client's macro plugin then wraps in `(...) as Distributed.
  // EntitlementPolicy` at witness synthesis. Both binary and interface
  // paths produce the same runtime policy.
  distributed func openDoorShortAnyOf() -> Bool { true }
  // CHECK: private static let $s51distributed_macro_validation_cross_module_interface6MyHomeC18openDoorShortAnyOf11EntitlementfMp_35__daval_openDoorShortAnyOf_accessorfMu_: Distributed._DistributedValidationAccessor = { outValue, type, hint, reserved in
  // CHECK: try Distributed.DistributedValidation.evaluate((Distributed::EntitlementPolicy.anyOf([Distributed::EntitlementPolicy.entitlement("com.example.short-form-a"), Distributed::EntitlementPolicy.entitlement("com.example.short-form-b")])) as Distributed.EntitlementPolicy)

  // Variadic short-form (`.anyOf(a, b)`, no array literal) inherited across
  // the interface-rebuild boundary. The interface printer resolves the
  // implicit member to the variadic `EntitlementPolicy.anyOf(_:)` factory
  // and reprints the call in fully-qualified form (a variadic argument list,
  // not an array literal).
  distributed func openDoorVariadicAnyOf() -> Bool { true }
  // CHECK: __daval_openDoorVariadicAnyOf_accessorfMu_: Distributed._DistributedValidationAccessor = { outValue, type, hint, reserved in
  // CHECK: try Distributed.DistributedValidation.evaluate((Distributed::EntitlementPolicy.anyOf(Distributed::EntitlementPolicy.entitlement("com.example.variadic-a"), Distributed::EntitlementPolicy.entitlement("com.example.variadic-b"))) as Distributed.EntitlementPolicy)

  // `@ValidateRemoteCall(.requireCustomEntitlement)` inherited across the
  // interface-rebuild boundary. The named factory reference is re-parsed
  // from the preserved arg text and resolves against the producer module's
  // extension on `RemoteCallValidator` (imported transitively). The
  // interface printer normalizes the implicit-member syntax to
  // `Distributed::RemoteCallValidator.requireCustomEntitlement`.
  distributed func openDoorCustom() -> Bool { true }
  // CHECK: private static let $s51distributed_macro_validation_cross_module_interface6MyHomeC14openDoorCustom18ValidateRemoteCallfMp_31__daval_openDoorCustom_accessorfMu_: Distributed._DistributedValidationAccessor = { outValue, type, hint, reserved in
  // CHECK: let validator: Distributed.RemoteCallValidator<MyHome.ActorSystem> = Distributed.RemoteCallValidator<MyHome.ActorSystem>(Distributed::RemoteCallValidator<FakeDistributedActorSystems::FakeRoundtripActorSystem>.requireCustomEntitlement)
}
