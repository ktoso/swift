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
// the validation accessor with the same string payload.
//
// Serialization preserves the macro `CustomAttr` and its argument list (via
// `@preservedInInterface`). On the client side, the requirement's
// `CustomAttr` arrives with an invalid `AtLoc` (never appeared in the
// client's source). `inheritDistributedValidationAttrs` synthesizes a fresh
// `@Entitlement("...")` source buffer at the witness's location, parses it,
// and attaches the resulting `CustomAttr` - now carrying valid source
// locations pointing into that buffer - to the witness. The attached-macro
// plugin walks the buffer, finds a real `AttributeSyntax` node, and expands
// the validation accessor on the witness as if the user had written it there.
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
// FileCheck the emitted validation accessor. Capture the dump once, then
// FileCheck it twice: the default prefix asserts each accessor's contents,
// the DEDUP prefix asserts exactly one accessor per witness (see end of file).
// RUN: %target-swift-frontend -typecheck -target %target-swift-6.0-abi-triple -plugin-path %swift-plugin-dir -parse-as-library -I %t -dump-macro-expansions %s > %t/expansion.txt 2>&1
// RUN: %FileCheck %s < %t/expansion.txt
// RUN: %FileCheck %s --check-prefix=DEDUP < %t/expansion.txt

import Distributed
import FakeDistributedActorSystems
import AdminProtocol

@available(SwiftStdlib 6.5, *)
distributed actor MyHome: HomeAdmin {
  typealias ActorSystem = FakeRoundtripActorSystem

  // Witness has no attribute; the compiler inherits `@Entitlement` from the
  // (imported, deserialized) protocol requirement. The accessor must carry
  // the string that was written on the protocol requirement in the producer
  // module.
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
  // CHECK-NEXT: private static let $s48distributed_macro_validation_cross_module_binary6MyHomeC8openDoor11EntitlementfMp_25__daval_openDoor_accessorfMu_: Distributed._DistributedValidationAccessor = { outValue, type, hint, reserved in
  // CHECK-NEXT: let expected: Any.Type = Distributed.RemoteCallValidator<MyHome.ActorSystem>.self
  // CHECK-NEXT: let requested = type.load(as: Any.Type.self)
  // CHECK-NEXT: guard requested == expected else {
  // CHECK-NEXT: return false
  // CHECK-NEXT: }
  // CHECK-NEXT: let validator: Distributed.RemoteCallValidator<MyHome.ActorSystem> = Distributed.RemoteCallValidator<MyHome.ActorSystem>({ _ in
  // CHECK-NEXT: try Distributed.DistributedValidation.evaluate(Distributed.EntitlementPolicy.entitlement("com.example.cross-module"))
  // CHECK-NEXT: })

  // Second requirement with a composite `.anyOf(...)` policy inherited
  // from the protocol. The accessor must reproduce the qualified policy
  // expression from the producer source.
  distributed func openDoorAnyOf() -> Bool { true }
  // CHECK: private static let $s48distributed_macro_validation_cross_module_binary6MyHomeC13openDoorAnyOf11EntitlementfMp_30__daval_openDoorAnyOf_accessorfMu_: Distributed._DistributedValidationAccessor = { outValue, type, hint, reserved in
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
  // CHECK: private static let $s48distributed_macro_validation_cross_module_binary6MyHomeC18openDoorShortAnyOf11EntitlementfMp_35__daval_openDoorShortAnyOf_accessorfMu_: Distributed._DistributedValidationAccessor = { outValue, type, hint, reserved in
  // CHECK: try Distributed.DistributedValidation.evaluate((.anyOf([
  // CHECK-NEXT: .entitlement("com.example.short-form-a"),
  // CHECK-NEXT: .entitlement("com.example.short-form-b"),
  // CHECK-NEXT: ])) as Distributed.EntitlementPolicy)

  // Fourth requirement with a variadic `.anyOf(a, b)` short-form: nested
  // policies listed directly, no array literal. The preserved arg text
  // round-trips the bracket-less spelling to the witness, and the same
  // `(...) as Distributed.EntitlementPolicy` wrap lets it resolve to the
  // variadic `EntitlementPolicy.anyOf(_:)` factory.
  distributed func openDoorVariadicAnyOf() -> Bool { true }
  // CHECK: __daval_openDoorVariadicAnyOf_accessorfMu_: Distributed._DistributedValidationAccessor = { outValue, type, hint, reserved in
  // CHECK: try Distributed.DistributedValidation.evaluate((.anyOf(
  // CHECK-NEXT: .entitlement("com.example.variadic-a"),
  // CHECK-NEXT: .entitlement("com.example.variadic-b"),
  // CHECK-NEXT: )) as Distributed.EntitlementPolicy)

  // `@ValidateRemoteCall(.requireCustomEntitlement)` inherited from the
  // protocol requirement. The named factory reference resolves against the
  // producer module's extension on `RemoteCallValidator` (which the client
  // imports transitively via `import AdminProtocol`).
  distributed func openDoorCustom() -> Bool { true }
  // CHECK: private static let $s48distributed_macro_validation_cross_module_binary6MyHomeC14openDoorCustom18ValidateRemoteCallfMp_31__daval_openDoorCustom_accessorfMu_: Distributed._DistributedValidationAccessor = { outValue, type, hint, reserved in
  // CHECK: let validator: Distributed.RemoteCallValidator<MyHome.ActorSystem> = Distributed.RemoteCallValidator<MyHome.ActorSystem>(.requireCustomEntitlement)
}

// Exactly one validation accessor per witness - guards the cross-module dedup
// in inheritDistributedValidationAttrs (was 2/3/4/5 duplicate accessors before
// deduping on preserved arg text). Each expected accessor is listed once, in
// source order; the trailing NOT fails on any further accessor (a duplicate
// re-clone appends extra copies, piling up at/after the last witness).
// DEDUP: __daval_openDoor_accessorfMu
// DEDUP: __daval_openDoorAnyOf_accessorfMu
// DEDUP: __daval_openDoorShortAnyOf_accessorfMu
// DEDUP: __daval_openDoorVariadicAnyOf_accessorfMu
// DEDUP: __daval_openDoorCustom_accessorfMu
// DEDUP-NOT: accessorfMu
