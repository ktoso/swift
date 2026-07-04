// REQUIRES: swift_swift_parser, asserts
//
// UNSUPPORTED: back_deploy_concurrency
// REQUIRES: concurrency
// REQUIRES: distributed
//
// End-to-end cross-module test: `@Entitlement("...")` is written on a
// `distributed func` requirement inside a protocol declared in module
// `AdminProtocol`. The client module never sees the source of that protocol
// (only the emitted `.swiftmodule`), yet the compiler inherits the
// `@Entitlement` attribute onto the conforming actor's witness and emits
// the `__daval_*_record` with the same string payload.
//
// Serialization preserves the macro `CustomAttr` and its argument list (via
// `@preservedInInterface`). On the client side, the requirement's
// `CustomAttr` arrives with an invalid `AtLoc` (never appeared in the
// client's source). `inheritDistributedValidationAttrs` synthesizes a fresh
// `@Entitlement("...")` source buffer at the witness's location, parses it,
// and attaches the resulting `CustomAttr` - now carrying valid source
// locations pointing into that buffer - to the witness. The attached-macro
// plugin walks the buffer, finds a real `AttributeSyntax` node, and expands
// the section record on the witness as if the user had written it there.
//
// RUN: %empty-directory(%t)
//
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems -target %target-swift-6.0-abi-triple %S/../Inputs/FakeDistributedActorSystems.swift
//
// Producer: emit only the .swiftmodule (no interface) so the client is
// forced through the direct-serialize path.
// RUN: %target-swift-frontend -emit-module -emit-module-path %t/AdminProtocol.swiftmodule -module-name AdminProtocol -target %target-swift-6.0-abi-triple -plugin-path %swift-plugin-dir -parse-as-library -I %t %S/Inputs/AdminProtocol.swift
//
// Consumer: type-checks the actor with -dump-macro-expansions so we can
// FileCheck the emitted section record.
// RUN: %target-swift-frontend -typecheck -target %target-swift-6.0-abi-triple -plugin-path %swift-plugin-dir -parse-as-library -I %t -dump-macro-expansions %s 2>&1 | %FileCheck %s

import Distributed
import FakeDistributedActorSystems
import AdminProtocol

@available(SwiftStdlib 6.5, *)
distributed actor MyHome: HomeAdmin {
  typealias ActorSystem = FakeRoundtripActorSystem

  // Witness has no attribute; the compiler inherits `@Entitlement` from the
  // (imported, deserialized) protocol requirement. The section record must
  // carry the string that was written on the protocol requirement in the
  // producer module.
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
  // CHECK-NEXT: try Distributed.DistributedValidation.evaluate(Distributed.EntitlementPolicy.entitlement("com.example.cross-module"))
  // CHECK-NEXT: })

  // Second requirement with a composite `.anyOf(...)` policy inherited
  // from the protocol. The section record must reproduce the qualified
  // policy expression from the producer source.
  distributed func openDoorAnyOf() -> Bool { true }
  // CHECK: private static let __daval_openDoorAnyOf_record: Distributed._DistributedValidationRecord = (
  // CHECK: try Distributed.DistributedValidation.evaluate((Distributed.EntitlementPolicy.anyOf([
  // CHECK-NEXT: .entitlement("com.example.cross-module"),
  // CHECK-NEXT: .entitlement("com.example.admin"),
  // CHECK-NEXT: ])) as Distributed.EntitlementPolicy)

  // Third requirement with a bare `.anyOf(...)` short-form. The macro plugin
  // wraps the preserved arg text in `(...) as Distributed.EntitlementPolicy`
  // at the witness site, so implicit-member syntax resolves against the enum
  // type even though the producer source did not spell out `Distributed.
  // EntitlementPolicy` in front of `.anyOf`.
  distributed func openDoorShortAnyOf() -> Bool { true }
  // CHECK: private static let __daval_openDoorShortAnyOf_record: Distributed._DistributedValidationRecord = (
  // CHECK: try Distributed.DistributedValidation.evaluate((.anyOf([
  // CHECK-NEXT: .entitlement("com.example.short-form-a"),
  // CHECK-NEXT: .entitlement("com.example.short-form-b"),
  // CHECK-NEXT: ])) as Distributed.EntitlementPolicy)
}
