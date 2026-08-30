// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems -target %target-swift-5.7-abi-triple %S/Inputs/FakeDistributedActorSystems.swift
// RUN: %target-swift-frontend -typecheck -verify -verify-ignore-unrelated -target %target-swift-5.7-abi-triple -I %t %s
// REQUIRES: concurrency
// REQUIRES: distributed

import Distributed
import FakeDistributedActorSystems

typealias DefaultDistributedActorSystem = FakeActorSystem

// A 'distributed' property is only meaningful inside a distributed actor,
// because checking it requires the enclosing actor's 'ActorSystem' to find the
// serialization requirement. This mirrors how a 'distributed' method is
// rejected outside a distributed actor

// ==== -----------------------------------------------------------------------
// MARK: Rejected placements

struct NotAnActor {
  distributed var inStruct: Int { 0 }
  // expected-error@-1{{'distributed' property can only be declared within 'distributed actor'}}
}

class AlsoNotAnActor {
  distributed var inClass: Int { 0 }
  // expected-error@-1{{'distributed' property can only be declared within 'distributed actor'}}
}

actor PlainActor {
  distributed var inPlainActor: Int { 0 }
  // expected-error@-1{{'distributed' property can only be declared within 'distributed actor'}}
}

// A plain protocol has no 'ActorSystem' to reduce against at all; this used to
// abort in getReducedTypeParameter
protocol PlainProtocol {
  distributed var inPlainProtocol: Int { get }
  // expected-error@-1{{'distributed' property can only be declared within 'distributed actor'}}
}

extension NotAnActor {
  distributed var inStructExtension: Int { 0 }
  // expected-error@-1{{'distributed' property can only be declared within 'distributed actor'}}
}

distributed var atFileScope: Int { 0 }
// expected-error@-1{{'distributed' property can only be declared within 'distributed actor'}}

func enclosingFunc() {
  distributed var localProperty: Int { 0 }
  // expected-error@-1{{'distributed' property can only be declared within 'distributed actor'}}
  _ = localProperty
}

// ==== -----------------------------------------------------------------------
// MARK: Accepted placements

distributed actor RealActor {
  distributed var inDistributedActor: Int { 0 } // ok
}

extension RealActor {
  distributed var inDistributedActorExtension: Int { 0 } // ok
}

protocol DistributedActorProtocol: DistributedActor
    where ActorSystem == FakeActorSystem {
  distributed var inDistributedActorProtocol: Int { get } // ok
}
