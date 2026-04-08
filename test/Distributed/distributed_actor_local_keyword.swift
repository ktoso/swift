// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems -target %target-swift-5.7-abi-triple %S/Inputs/FakeDistributedActorSystems.swift
// RUN: %target-swift-frontend -typecheck -verify -enable-experimental-feature DistributedActorLocalKeyword -disable-availability-checking -swift-version 6 -I %t 2>&1 %s
// REQUIRES: concurrency
// REQUIRES: distributed

import Distributed
import FakeDistributedActorSystems

typealias DefaultDistributedActorSystem = FakeActorSystem

distributed actor MyActor {
  var state: String = "stateful"
  func localOnly() -> String { "local" }
  distributed func remoteCallable() -> String { "remote" }
}

actor RegularActor {}
class MyClass {}

// ==== -----------------------------------------------------------------------
// MARK: Parameter position — concrete type

// distributed(local) in parameter position — does NOT throw on distributed calls
func useLocal(da: distributed(local) MyActor) async {
  // distributed(local) means known-local: no try, no await needed
  _ = da.remoteCallable() // OK
}

// distributed(local) accepts a distributed actor type
func acceptsLocal(da: distributed(local) MyActor) { } // OK

// ==== -----------------------------------------------------------------------
// MARK: Parameter position — generic type

func useGeneric<T: DistributedActor>(t: distributed(local) T) { } // OK

func useGenericConstrained<T: DistributedActor>(
  t: distributed(local) T
) where T.ActorSystem == FakeActorSystem { } // OK

// ==== -----------------------------------------------------------------------
// MARK: Init-returns-local — constructor creates a known-local actor

func testInitReturnsLocal() async {
  let da = MyActor(actorSystem: FakeActorSystem())
  // 'da' should be implicitly marked as distributed(local) because it was
  // just constructed locally — no 'try' needed
  _ = await da.remoteCallable() // OK
}

// ==== -----------------------------------------------------------------------
// MARK: distributed(local) on non-distributed-actor types

// distributed(local) on non-distributed-actor type
func bad1(x: distributed(local) String) {} // expected-error{{'distributed(local)' can only be used with a distributed actor type}}

// distributed(local) on regular actor
func bad2(x: distributed(local) RegularActor) {} // expected-error{{'distributed(local)' can only be used with a distributed actor type}}

// distributed(local) on class
func bad3(x: distributed(local) MyClass) {} // expected-error{{'distributed(local)' can only be used with a distributed actor type}}

// distributed(local) on struct
func bad4(x: distributed(local) Int) {} // expected-error{{'distributed(local)' can only be used with a distributed actor type}}

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
  // expected-note@-2{{remove '(local)' to declare a 'distributed func'}}
  distributed(local) var badVar: Int { 0 }
  // expected-error@-1{{'distributed(local)' cannot be used on declarations}}
  // expected-note@-2{{remove '(local)' to declare a 'distributed var'}}
}

// distributed(local) cannot be used on top-level func/var declarations
distributed(local) func topLevelBadFunc() {}
// expected-error@-1{{'distributed(local)' cannot be used on declarations}}
// expected-note@-2{{remove '(local)' to declare a 'distributed func'}}
distributed(local) var topLevelBadVar: Int { 0 }
// expected-error@-1{{'distributed(local)' cannot be used on declarations}}
// expected-note@-2{{remove '(local)' to declare a 'distributed var'}}

// ==== -----------------------------------------------------------------------
// MARK: Closure parameter position

func testClosureParam() async {
  let fn: (distributed(local) MyActor) async -> String = { da in
    return da.remoteCallable() // OK, known-local: no try, no await needed
  }
  let da = MyActor(actorSystem: FakeActorSystem())
  _ = await fn(da)
}

// ==== -----------------------------------------------------------------------
// MARK: Optional wrapping

func acceptsOptional(da: distributed(local) MyActor?) { } // OK

func testOptionalParam() async {
  let da: MyActor? = MyActor(actorSystem: FakeActorSystem())
  acceptsOptional(da: da)
}

// ==== -----------------------------------------------------------------------
// MARK: Return type position

func returnsLocal(system: FakeActorSystem) -> distributed(local) MyActor {
  MyActor(actorSystem: system)
}

func testReturnLocal() async throws {
  let system = FakeActorSystem()
  let da = returnsLocal(system: system)
  // Note: distributed(local) in return position validates the return type
  // but does not propagate known-locality to the call site
  _ = try await da.remoteCallable()
}

// ==== -----------------------------------------------------------------------
// MARK: Negative — non-distributed-actor in return position

func badReturn1() -> distributed(local) String { "" }
// expected-error@-1{{'distributed(local)' can only be used with a distributed actor type}}

func badReturn2() -> distributed(local) RegularActor { fatalError() }
// expected-error@-1{{'distributed(local)' can only be used with a distributed actor type}}

// ==== -----------------------------------------------------------------------
// MARK: Interaction with isolated

// 'isolated' and 'distributed(local)' can coexist — isolated provides actor
// isolation context, distributed(local) provides known-locality
func bothIsolatedAndLocal(da: isolated distributed(local) MyActor) async {
  _ = da.remoteCallable() // OK: known-local, no try needed
  _ = da.localOnly() // OK: known-local and isolated, can access local state
}

// ==== -----------------------------------------------------------------------
// MARK: Negative — distributed(local) in invalid positions

// distributed(local) on local variable type annotation
func badLocalVar() {
  let _: distributed(local) MyActor = MyActor(actorSystem: FakeActorSystem())
  // expected-error@-1{{'distributed(local)' may only be used on parameters and results}}
}

// distributed(local) on stored property
distributed actor ActorWithBadProp {
  var bad: distributed(local) MyActor? // expected-error{{'distributed(local)' may only be used on parameters and results}}
}

// ==== -----------------------------------------------------------------------
// MARK: Protocol with distributed(local) parameter

protocol LocalActorConsumer {
  func consume(da: distributed(local) MyActor) async
}

// Conforming type can satisfy the requirement
distributed actor ConformingActor: LocalActorConsumer {
  nonisolated func consume(da: distributed(local) MyActor) async {
    _ = da.remoteCallable() // OK: known-local
  }
}
