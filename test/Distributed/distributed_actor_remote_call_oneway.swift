// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems -target %target-swift-6.2-abi-triple -disable-availability-checking %S/Inputs/FakeDistributedActorSystems.swift
// RUN: %target-swift-frontend -typecheck -verify -target %target-swift-6.2-abi-triple -disable-availability-checking -enable-experimental-feature DistributedRemoteCallSemantics -I %t 2>&1 %s
// REQUIRES: concurrency
// REQUIRES: distributed
// REQUIRES: swift_feature_DistributedRemoteCallSemantics

import Distributed
import FakeDistributedActorSystems

typealias DefaultDistributedActorSystem = FakeActorSystem

// ==== ------------------------------------------------------------------------
// MARK: Positive cases: @remoteCall(oneway) on Void-returning distributed funcs

distributed actor Greeter {
  // Synchronous Void func is accepted.
  @remoteCall(oneway)
  distributed func thanks() {}

  // Async Void func is accepted.
  @remoteCall(oneway)
  distributed func ping() async {}

  // Explicit '-> Void' is accepted.
  @remoteCall(oneway)
  distributed func ack() -> Void {}
}

// ==== ------------------------------------------------------------------------
// MARK: Negative cases: @remoteCall(oneway) rejects non-Void return

distributed actor NonVoidGreeter {
  // expected-error@+1{{'@remoteCall(oneway)' instance method 'ohai()' must return 'Void'}}
  @remoteCall(oneway)
  distributed func ohai() -> Int { 0 }

  // expected-error@+1{{'@remoteCall(oneway)' instance method 'greet(name:)' must return 'Void'}}
  @remoteCall(oneway)
  distributed func greet(name: String) async -> String { name }
}

// ==== ------------------------------------------------------------------------
// MARK: Negative cases: @remoteCall(oneway) rejects computed properties

distributed actor PropGreeter {
  // expected-error@+1{{'@remoteCall(oneway)' cannot be applied to property 'status'; oneway calls do not return a value}}
  @remoteCall(oneway)
  distributed var status: Int { 0 }
}

// ==== ------------------------------------------------------------------------
// MARK: Negative cases: @remoteCall(oneway) requires a 'distributed' member

struct NotAnActor {
  // expected-error@+1{{'@remoteCall' can only be applied to 'distributed' methods and computed properties}}
  @remoteCall(oneway)
  func plain() {}
}

distributed actor MixedGreeter {
  // expected-error@+1{{'@remoteCall' can only be applied to 'distributed' methods and computed properties}}
  @remoteCall(oneway)
  func localOnly() {}
}

// ==== ------------------------------------------------------------------------
// MARK: Negative case: 'blocking' + 'oneway' is an illegal combination

distributed actor Contradictory {
  // expected-error@+1{{illegal combination of remote call options: 'blocking' remote call cannot be 'oneway'}}
  @remoteCall(blocking, oneway)
  distributed func confused() {}
}
