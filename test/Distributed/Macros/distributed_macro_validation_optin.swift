// REQUIRES: swift_swift_parser, asserts
//
// UNSUPPORTED: back_deploy_concurrency
// REQUIRES: concurrency
// REQUIRES: distributed
//
// Verifies the actor-system opt-in gates which validation macros are inherited
// from distributed protocol requirements onto witnesses:
//
//   - `FakeRoundtripActorSystem` opts into
//     `InheritMacros<ValidateRemoteCallMacro, EntitlementMacro>` (see
//     `Inputs/FakeDistributedActorSystems.swift`), so BOTH `@ValidateRemoteCall`
//     and `@Entitlement` are inherited onto its actors' witnesses.
//   - `FakeActorSystem` declares no `RemoteCallValidation`, so it uses the
//     default (`InheritMacros<ValidateRemoteCallMacro>`): `@ValidateRemoteCall`
//     is inherited, `@Entitlement` is NOT.
//
// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems -target %target-swift-6.0-abi-triple %S/../Inputs/FakeDistributedActorSystems.swift
// RUN: %target-swift-frontend -typecheck -target %target-swift-6.0-abi-triple -plugin-path %swift-plugin-dir -parse-as-library -I %t %S/../Inputs/FakeDistributedActorSystems.swift -dump-macro-expansions %s > %t/expansion.txt 2>&1
// RUN: %FileCheck %s < %t/expansion.txt
// RUN: %FileCheck %s --check-prefix=NOENT < %t/expansion.txt

import Distributed

// The generic macro parameter of `@ValidateRemoteCall` needs a known
// `ActorSystem` at every attachment site, including protocol requirements.
// Constrain the factory to `FakeActorSystem` here so it matches the protocol
// requirement's fixed `ActorSystem` below without ambiguity.
@available(SwiftStdlib 6.5, *)
extension RemoteCallValidator where ActorSystem == FakeActorSystem {
  public static var trace: RemoteCallValidator { RemoteCallValidator { _ in } }
}

// Requirements carry distinct entitlement strings so the opted-in vs default
// cases are unambiguous in the combined macro-expansion dump.
@available(SwiftStdlib 6.5, *)
protocol OptedInService: DistributedActor {
  @Entitlement("com.example.opted-in-gate")
  distributed func guarded() -> Bool
}

// Fixing `ActorSystem` on the protocol so `@ValidateRemoteCall(.trace)` on
// the requirement can bind the macro's `ActorSystem` type parameter and find
// the `.trace` factory.
@available(SwiftStdlib 6.5, *)
protocol DefaultService: DistributedActor where ActorSystem == FakeActorSystem {
  @Entitlement("com.example.default-gate")
  distributed func guarded() -> Bool
  @ValidateRemoteCall(.trace)
  distributed func traced() -> Bool
}

// Opts into Entitlement: `@Entitlement` is inherited onto `guarded`.
@available(SwiftStdlib 6.5, *)
distributed actor OptedIn: OptedInService {
  typealias ActorSystem = FakeRoundtripActorSystem
  distributed func guarded() -> Bool { true }
  // CHECK-DAG: try Distributed.DistributedValidation.evaluate(Distributed.EntitlementPolicy.entitlement("com.example.opted-in-gate"))
}

// Uses the default (ValidateRemoteCall only): `@ValidateRemoteCall` is
// inherited onto `traced`, but `@Entitlement` is NOT inherited onto `guarded`.
@available(SwiftStdlib 6.5, *)
distributed actor DefaultOnly: DefaultService {
  typealias ActorSystem = FakeActorSystem
  distributed func guarded() -> Bool { true }
  distributed func traced() -> Bool { true }
  // CHECK-DAG: let validator: Distributed.RemoteCallValidator<{{.*}}.ActorSystem> = Distributed.RemoteCallValidator<{{.*}}.ActorSystem>(.trace)
}

// The default-system actor must NOT inherit @Entitlement, so its gate string
// never appears in any emitted accessor.
// NOENT-NOT: com.example.default-gate
