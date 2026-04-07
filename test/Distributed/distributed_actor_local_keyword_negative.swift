// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems -target %target-swift-5.7-abi-triple %S/Inputs/FakeDistributedActorSystems.swift
// RUN: %target-swift-frontend -typecheck -verify -enable-experimental-feature DistributedActorLocalKeyword -disable-experimental-parser-round-trip -disable-availability-checking -swift-version 6 -I %t 2>&1 %s
// REQUIRES: concurrency
// REQUIRES: distributed

import Distributed
import FakeDistributedActorSystems

typealias DefaultDistributedActorSystem = FakeActorSystem

distributed actor MyActor {
  func localOnly() -> String { "local" }
}

// ==== -----------------------------------------------------------------------
// MARK: distributed(local) on non-distributed-actor types

// distributed(local) on non-distributed-actor type
func bad1(x: distributed(local) String) {} // expected-error{{'distributed(local)' parameter must be a distributed actor type}}

// distributed(local) on regular actor
actor RegularActor {}
func bad2(x: distributed(local) RegularActor) {} // expected-error{{'distributed(local)' parameter must be a distributed actor type}}

// distributed(local) on class
class MyClass {}
func bad3(x: distributed(local) MyClass) {} // expected-error{{'distributed(local)' parameter must be a distributed actor type}}

// distributed(local) on struct
func bad4(x: distributed(local) Int) {} // expected-error{{'distributed(local)' parameter must be a distributed actor type}}

// ==== -----------------------------------------------------------------------
// MARK: distributed(local) on declarations

// distributed(local) cannot be used on actor declarations
distributed(local) actor BadActor {}
// expected-error@-1{{'distributed(local)' cannot be used on declarations}}
// expected-note@-2{{remove '(local)' to declare a 'distributed actor' which may be remote}}{{12-19=}}
// expected-note@-3{{remove 'distributed' to declare a local-only 'actor'}}{{1-20=}}

// distributed(local) cannot be used on func/var declarations inside a type
distributed actor GoodActor {
  distributed(local) func badMethod() {}
  // expected-error@-1{{'distributed(local)' cannot be used on declarations}}
  // expected-note@-2{{remove '(local)' to declare a 'distributed actor' which may be remote}}
  // expected-note@-3{{remove 'distributed' to declare a local-only 'actor'}}
  distributed(local) var badVar: Int { 0 }
  // expected-error@-1{{'distributed(local)' cannot be used on declarations}}
  // expected-note@-2{{remove '(local)' to declare a 'distributed actor' which may be remote}}
  // expected-note@-3{{remove 'distributed' to declare a local-only 'actor'}}
}
