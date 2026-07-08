// REQUIRES: swift_swift_parser, asserts
//
// UNSUPPORTED: back_deploy_concurrency
// REQUIRES: concurrency
// REQUIRES: distributed
//
// RUN: %empty-directory(%t)

// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems -target %target-swift-6.0-abi-triple %S/../Inputs/FakeDistributedActorSystems.swift
// RUN: %target-swift-frontend -typecheck -target %target-swift-6.0-abi-triple -plugin-path %swift-plugin-dir -parse-as-library -I %t %S/../Inputs/FakeDistributedActorSystems.swift -dump-macro-expansions %s 2>&1 | %FileCheck %s

// Verifies the expanded output of @Entitlement and @ValidateRemoteCall: each
// emits a single accessor global (per-object-format accessor section, @used,
// deprecation marker) whose captureless closure materializes the validation
// policy into the out-parameter. The identifying `swift5_daval` record is
// emitted by the compiler (IRGen), not the macro - it carries the target's
// mangled distributed-thunk name and a relative pointer to this accessor - so
// it does not appear in macro-expansion output.
//
// The accessor body includes a runtime cross-check on the incoming `type`
// pointer so a validator emitted for one actor system refuses to materialize
// into a caller expecting a different one; the emitted validator itself is
// typed as `RemoteCallValidator<MyHome.ActorSystem>`.

import Distributed
import FakeDistributedActorSystems

@available(SwiftStdlib 6.5, *)
extension RemoteCallValidator where ActorSystem == FakeRoundtripActorSystem {
  public static var noop: RemoteCallValidator { RemoteCallValidator { _ in } }
}

@available(SwiftStdlib 6.5, *)
distributed actor MyHome {
  typealias ActorSystem = FakeRoundtripActorSystem

  @Entitlement("com.example.openDoor")
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
  // The accessor name is compiler-issued via `context.makeUniqueName(...)`
  // seeded with `__daval_<method>_accessor`. This gives each expansion a
  // conflict-free name so stacked or witness+protocol-inherited attributes
  // can coexist on the same declaration. The mangled shape is
  // `$s<module><type><method>{Entitlement|ValidateRemoteCall}fMp_25__daval_<method>_accessorfMu_`.
  // CHECK-NEXT: private static let $s27FakeDistributedActorSystems6MyHomeC8openDoor11EntitlementfMp_25__daval_openDoor_accessorfMu_: Distributed._DistributedValidationAccessor = { outValue, type, hint, reserved in
  // CHECK-NEXT: let expected: Any.Type = Distributed.RemoteCallValidator<MyHome.ActorSystem>.self
  // CHECK-NEXT: let requested = type.load(as: Any.Type.self)
  // CHECK-NEXT: guard requested == expected else {
  // CHECK-NEXT: return false
  // CHECK-NEXT: }
  // CHECK-NEXT: let validator: Distributed.RemoteCallValidator<MyHome.ActorSystem> = Distributed.RemoteCallValidator<MyHome.ActorSystem>({ _ in
  // CHECK-NEXT: try Distributed.DistributedValidation.evaluate(Distributed.EntitlementPolicy.entitlement("com.example.openDoor"))
  // CHECK-NEXT: })
  // CHECK-NEXT: outValue.assumingMemoryBound(to: Distributed.RemoteCallValidator<MyHome.ActorSystem>.self)
  // CHECK-NEXT: .initialize(to: validator)
  // CHECK-NEXT: return true
  // CHECK-NEXT: }

  @ValidateRemoteCall(.noop)
  distributed func openWindow() -> Bool { true }
  // CHECK: #if objectFormat(MachO)
  // CHECK-NEXT: @section("__DATA_CONST,__swift5_davala")
  // CHECK-NEXT: #elseif objectFormat(ELF) || objectFormat(Wasm)
  // CHECK-NEXT: @section("swift5_davala")
  // CHECK-NEXT: #elseif objectFormat(COFF)
  // CHECK-NEXT: @section(".sw5davala$B")
  // CHECK-NEXT: #endif
  // CHECK-NEXT: @used
  // CHECK-NEXT: @available(*, deprecated, message: "Implementation detail of Distributed. Do not use directly.")
  // CHECK-NEXT: private static let $s27FakeDistributedActorSystems6MyHomeC10openWindow18ValidateRemoteCallfMp_27__daval_openWindow_accessorfMu_: Distributed._DistributedValidationAccessor = { outValue, type, hint, reserved in
  // CHECK-NEXT: let expected: Any.Type = Distributed.RemoteCallValidator<MyHome.ActorSystem>.self
  // CHECK-NEXT: let requested = type.load(as: Any.Type.self)
  // CHECK-NEXT: guard requested == expected else {
  // CHECK-NEXT: return false
  // CHECK-NEXT: }
  // CHECK-NEXT: let validator: Distributed.RemoteCallValidator<MyHome.ActorSystem> = Distributed.RemoteCallValidator<MyHome.ActorSystem>(.noop)
  // CHECK-NEXT: outValue.assumingMemoryBound(to: Distributed.RemoteCallValidator<MyHome.ActorSystem>.self)
  // CHECK-NEXT: .initialize(to: validator)
  // CHECK-NEXT: return true
  // CHECK-NEXT: }
}
