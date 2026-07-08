// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems -target %target-swift-6.0-abi-triple %S/../Inputs/FakeDistributedActorSystems.swift
// RUN: %target-swift-frontend -typecheck -verify -verify-ignore-unrelated -target %target-swift-6.0-abi-triple -plugin-path %swift-plugin-dir -parse-as-library -I %t %S/../Inputs/FakeDistributedActorSystems.swift %s 2>&1

// UNSUPPORTED: back_deploy_concurrency
// REQUIRES: swift_swift_parser, asserts
// REQUIRES: concurrency
// REQUIRES: distributed

import Distributed

@available(SwiftStdlib 6.5, *)
extension RemoteCallValidator where ActorSystem == FakeRoundtripActorSystem {
  public static var exampleValidator: RemoteCallValidator {
    RemoteCallValidator { _ in }
  }
}

@available(SwiftStdlib 6.5, *)
distributed actor MyHome {
  typealias ActorSystem = FakeRoundtripActorSystem

  // ==== -----------------------------------------------------------------------
  // MARK: `distributed func`/`distributed var` accepted forms

  @Entitlement("com.example")
  distributed func openDoor() -> Bool { true }

  @ValidateRemoteCall(.exampleValidator)
  distributed func openWindow() -> Bool { true }

  // ==== -----------------------------------------------------------------------
  // MARK: `func`/`var` without `distributed` modifier: missing-modifier diagnostic

  @Entitlement("com.example") // expected-error{{'@Entitlement' can only be applied to a 'distributed func' or 'distributed var'; add the 'distributed' modifier or remove '@Entitlement'}} expected-note{{Add 'distributed' modifier}}
  func plainFunc() {}

  @Entitlement("com.example") // expected-error{{'@Entitlement' can only be applied to a 'distributed func' or 'distributed var'; add the 'distributed' modifier or remove '@Entitlement'}} expected-note{{Add 'distributed' modifier}}
  var plainVar: Int { 42 }

  @ValidateRemoteCall(.exampleValidator) // expected-error{{'@ValidateRemoteCall' can only be applied to a 'distributed func' or 'distributed var'; add the 'distributed' modifier or remove '@ValidateRemoteCall'}} expected-note{{Add 'distributed' modifier}}
  func plainValidatedFunc() {}

  // ==== -----------------------------------------------------------------------
  // MARK: Non-func/var declaration kinds inside a distributed actor: rejected outright

  @Entitlement("com.example") // expected-error{{'@Entitlement' can only be applied to a 'distributed func' or 'distributed var', but was attached to 'subscript'}}
  subscript(_ x: Int) -> Int { 0 }

  @Entitlement("com.example") // expected-error{{'@Entitlement' can only be applied to a 'distributed func' or 'distributed var', but was attached to 'struct'}}
  struct NestedS {}

  @Entitlement("com.example") // expected-error{{'@Entitlement' can only be applied to a 'distributed func' or 'distributed var', but was attached to 'enum'}}
  enum NestedE {}
}
