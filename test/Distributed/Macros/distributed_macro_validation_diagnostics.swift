// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems -target %target-swift-6.0-abi-triple %S/../Inputs/FakeDistributedActorSystems.swift
// RUN: %target-swift-frontend -typecheck -verify -verify-ignore-unrelated -target %target-swift-6.0-abi-triple -plugin-path %swift-plugin-dir -parse-as-library -I %t %S/../Inputs/FakeDistributedActorSystems.swift %s 2>&1
//
// UNSUPPORTED: back_deploy_concurrency
// REQUIRES: swift_swift_parser, asserts
// REQUIRES: concurrency
// REQUIRES: distributed
//
// Diagnostics test for `@Entitlement` / `@ValidateRemoteCall` argument
// shapes that DO NOT trigger a macro-plugin diagnostic today. Documented
// here so a future change to the macro plugin (e.g. tightening the argument
// grammar to reject non-const-expressible policies at expansion time) has
// an explicit contract to change.
//
// Attachment-site diagnostics (missing `distributed` modifier, wrong decl
// kind) are covered by `distributed_macro_validation_invalid_target.swift`.

import Distributed

@available(SwiftStdlib 6.5, *)
extension RemoteCallValidator where ActorSystem == FakeRoundtripActorSystem {
  public static var exampleValidator: RemoteCallValidator {
    RemoteCallValidator { _ in }
  }
}

let runtimeString = "runtime-value"

@available(SwiftStdlib 6.5, *)
distributed actor Accepted {
  typealias ActorSystem = FakeRoundtripActorSystem

  // ==== -----------------------------------------------------------------------
  // MARK: Non-literal `.entitlement(...)` argument
  //
  // The macro plugin extracts the argument as source text and emits it inside
  // an accessor-closure body. A non-string-literal reference (e.g. a global
  // `let` binding) is valid Swift, so no diagnostic fires and the emitted
  // code compiles cleanly.

  @Entitlement(.entitlement(runtimeString))
  distributed func openA() -> Bool { true }

  // ==== -----------------------------------------------------------------------
  // MARK: `.anyOf` / `.allOf` with a mix of literal and non-literal leaves

  @Entitlement(.anyOf([.entitlement(runtimeString), .entitlement("literal")]))
  distributed func openB() -> Bool { true }

  @Entitlement(.allOf([.entitlement("literal"), .entitlement(runtimeString)]))
  distributed func openC() -> Bool { true }

  // ==== -----------------------------------------------------------------------
  // MARK: `@ValidateRemoteCall` with a named factory reference
  //
  // The macro's argument type is `RemoteCallValidator<ActorSystem>`, so a
  // named factory on a `RemoteCallValidator` extension (constrained to the
  // enclosing actor's `ActorSystem`) is the standard shape.

  @ValidateRemoteCall(.exampleValidator)
  distributed func openD() -> Bool { true }
}
