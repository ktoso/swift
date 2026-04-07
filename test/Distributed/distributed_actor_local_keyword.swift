// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems -target %target-swift-5.7-abi-triple %S/Inputs/FakeDistributedActorSystems.swift
// RUN: %target-swift-frontend -typecheck -verify -enable-experimental-feature DistributedActorLocalKeyword -disable-experimental-parser-round-trip -disable-availability-checking -swift-version 6 -I %t 2>&1 %s
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
