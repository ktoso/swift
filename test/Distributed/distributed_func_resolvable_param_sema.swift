// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems -target %target-swift-5.7-abi-triple %S/Inputs/FakeDistributedActorSystems.swift
// RUN: %target-swift-frontend -typecheck -verify -verify-ignore-unrelated -verify-ignore-unknown -target %target-swift-6.0-abi-triple -plugin-path %swift-plugin-dir -I %t 2>&1 %s
// REQUIRES: swift_swift_parser, asserts
// REQUIRES: concurrency
// REQUIRES: distributed

import Distributed
import FakeDistributedActorSystems

typealias DefaultDistributedActorSystem = FakeActorSystem

// ==== Sema accepts `some/any P` parameters when P is @Resolvable ------------

@Resolvable
protocol Greeter: DistributedActor, Codable where ActorSystem == FakeActorSystem {
  distributed func greet() -> String
}

@Resolvable
protocol PowerSwitch: DistributedActor, Codable where ActorSystem == FakeActorSystem {
  distributed func toggle()
}

distributed actor Worker {
  typealias ActorSystem = FakeActorSystem

  // OK: `some Greeter` and `any Greeter` parameters round-trip via $Greeter.
  distributed func sendSomeGreeter(_ g: some Greeter) {}
  distributed func sendAnyGreeter(_ g: any Greeter) {}

  // OK: a non-resolvable Codable param alongside a resolvable one.
  distributed func mixed(_ g: any Greeter, count: Int) {}
}

// ==== Negative: composition of two @Resolvable protocols is ambiguous -------

distributed actor BadComposition {
  typealias ActorSystem = FakeActorSystem

  // expected-error@+1{{contains more than one '@Resolvable' protocol}}
  distributed func ambiguous(_ g: any Greeter & PowerSwitch) {}
}

// ==== Negative: @Resolvable protocol without concrete ActorSystem ------------

@Resolvable
protocol GenericProto: DistributedActor, Codable {
  distributed func ping()
}

distributed actor GenericSystemUser {
  typealias ActorSystem = FakeActorSystem

  // expected-error@+1{{without a concrete 'ActorSystem' constraint}}
  distributed func sendGeneric(_ g: any GenericProto) {}
}
