// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems -disable-availability-checking %S/Inputs/FakeDistributedActorSystems.swift
// RUN: %target-swift-frontend -typecheck -verify -disable-availability-checking -I %t 2>&1 %s
// REQUIRES: concurrency
// REQUIRES: distributed

import Distributed
import FakeDistributedActorSystems

protocol Protocol_SerNotCodable_IdCodable: DistributedActor
  where ActorSystem == FakeCustomSerializationRoundtripActorSystem {
  distributed func test()
}

//extension Protocol_SerNotCodable_IdCodable {
//  distributed func test() {}
//}
//
//distributed actor Test : Protocol_SerNotCodable_IdCodable {
//  distributed func test() {}
//}

func test_Protocol_SerNotCodable_IdCodable(actor: any Protocol_SerNotCodable_IdCodable) {
  let _: any Codable = actor // OK, the ID was Codable, even though SerializationRequirement was something else

  // no implicit conformance
  let _: any CustomSerializationProtocol = actor // expected-error{{value of type 'any Protocol_SerNotCodable_IdCodable' does not conform to specified type 'CustomSerializationProtocol'}}

}
