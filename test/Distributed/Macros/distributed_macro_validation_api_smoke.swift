// REQUIRES: swift_swift_parser, asserts
//
// UNSUPPORTED: back_deploy_concurrency
// REQUIRES: concurrency
// REQUIRES: distributed
//
// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems -target %target-swift-6.0-abi-triple %S/../Inputs/FakeDistributedActorSystems.swift
// RUN: %target-swift-frontend -typecheck -target %target-swift-6.0-abi-triple -plugin-path %swift-plugin-dir -parse-as-library -I %t %S/../Inputs/FakeDistributedActorSystems.swift %s

// Compile-only smoke test: verifies the @Entitlement + runtime API surface
// integrate cleanly. Full runtime dispatch is exercised by
// distributed_actor_remoteCall_validation.swift once the tests infrastructure
// supports linking against a just-built swiftDistributed with new symbols.

import Distributed
import FakeDistributedActorSystems

// Recipe API: extend RemoteCallValidator with named factories, use them via
// implicit-member syntax on `@ValidateRemoteCall(.name)`.
@available(SwiftStdlib 6.5, *)
extension RemoteCallValidator where ActorSystem == FakeRoundtripActorSystem {
  public static var requireAdminRole: RemoteCallValidator {
    RemoteCallValidator { _ in
      // A real implementation would consult the receive-side context (e.g.
      // task-local entitlements, service context) and throw on rejection.
    }
  }

  public static func requireEntitlement(_ name: String) -> RemoteCallValidator {
    RemoteCallValidator { _ in }
  }
}

@available(SwiftStdlib 6.5, *)
distributed actor SecureHome {
  typealias ActorSystem = FakeRoundtripActorSystem

  distributed func openWindow() -> Bool { true }

  @Entitlement("com.example.open-door")
  distributed func openDoor() -> Bool { true }

  @Entitlement(.anyOf([
    .entitlement("com.example.admin"),
    .entitlement("com.example.super-admin"),
  ]))
  distributed func openSafe() -> Bool { true }

  // Variadic short-form: nested policies listed without an array literal.
  // Resolves to the `EntitlementPolicy.anyOf(_:)` / `.allOf(_:)` factory.
  @Entitlement(.anyOf(
    .entitlement("com.example.admin"),
    .entitlement("com.example.super-admin"),
  ))
  distributed func openSafeVariadic() -> Bool { true }

  @Entitlement(.allOf(.entitlement("com.example.admin"), "com.example.mfa"))
  distributed func openVaultVariadic() -> Bool { true }

  @ValidateRemoteCall(.requireAdminRole)
  distributed func openBackDoorSecure() -> Bool { true }

  @ValidateRemoteCall(.requireEntitlement("open-vault"))
  distributed func openVault() -> Bool { true }
}

// Also verify the runtime API is reachable from user code (`lookup` is
// internal; the developer-facing entrypoint is `system.validate(...)`, tested
// in the runtime tests).
@available(SwiftStdlib 6.5, *)
func exerciseAPI() {
  DistributedValidation.$currentEntitlements.withValue(["foo"]) {
    let _ = DistributedValidation.currentEntitlements
  }
}
