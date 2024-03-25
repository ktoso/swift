// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems -disable-availability-checking %S/Inputs/FakeDistributedActorSystems.swift
// RUN: %target-swift-frontend -typecheck -verify -verify-ignore-unknown -disable-availability-checking -I %t 2>&1 %s
// REQUIRES: concurrency
// REQUIRES: distributed

import Distributed
import FakeDistributedActorSystems

struct NotCodable {}

protocol NoSerializationRequirementYet: DistributedActor {

  // NOTE: Notes here come from the conforming actor SpecifyRequirement
  // expected-note@+1{{result type 'NotCodable' of distributed instance method 'test' does not conform to serialization requirement 'Codable'}}
  distributed func test() -> NotCodable

  // NOTE: Notes here come from the conforming actor SpecifyRequirement
  // expected-note@+1{{result type 'NotCodable' of distributed instance method 'testAT' does not conform to serialization requirement 'Codable'}}
  distributed func testAT() async throws -> NotCodable
}

// expected-error@+2{{distributed actor 'SpecifyRequirement' cannot conform to 'NoSerializationRequirementYet' because of serialization requirement error in distributed instance method 'testAT()'}}
// expected-error@+1{{distributed actor 'SpecifyRequirement' cannot conform to 'NoSerializationRequirementYet' because of serialization requirement error in distributed instance method 'test()'}}
distributed actor SpecifyRequirement: NoSerializationRequirementYet {
  typealias ActorSystem = FakeActorSystem

  // expected-error@+1{{result type 'NotCodable' of distributed instance method 'test' does not conform to serialization requirement 'Codable'}}
  distributed func test() -> NotCodable {
    .init()
  }

  // expected-error@+1{{result type 'NotCodable' of distributed instance method 'testAT' does not conform to serialization requirement 'Codable'}}
  distributed func testAT() async throws -> NotCodable {
    .init()
  }

}

protocol ProtocolWithChecksSystem: DistributedActor
  where ActorSystem == FakeActorSystem {
  // Error comes from the protocol itself
  // expected-error@+3{{result type 'NotCodable' of distributed instance method 'testAT' does not conform to serialization requirement 'Codable'}}
  // Note comes from adopting type
  // expected-note@+1{{result type 'NotCodable' of distributed instance method 'testAT' does not conform to serialization requirement 'Codable'}}
  distributed func testAT() async throws -> NotCodable
}

// expected-error@+1{{distributed actor 'ProtocolWithChecksSystemDA' cannot conform to 'ProtocolWithChecksSystem' because of serialization requirement error in distributed instance method 'testAT()'}}
distributed actor ProtocolWithChecksSystemDA: ProtocolWithChecksSystem {
  // expected-error@+1{{result type 'NotCodable' of distributed instance method 'testAT' does not conform to serialization requirement 'Codable'}}
  distributed func testAT() async throws -> NotCodable { .init() }
}

protocol ProtocolWithChecksSeqReq: DistributedActor
  where Self.SerializationRequirement == Codable {
  // Error comes from the protocol itself
  // expected-error@+3{{result type 'NotCodable' of distributed instance method 'testAT' does not conform to serialization requirement 'Codable'}}
  // Note comes from adopting type
  // expected-note@+1{{result type 'NotCodable' of distributed instance method 'testAT' does not conform to serialization requirement 'Codable'}}
  distributed func testAT() async throws -> NotCodable
}
distributed actor ProtocolWithChecksSeqReqDA_MissingSystem: ProtocolWithChecksSeqReq {
  // expected-error@-1{{distributed actor 'ProtocolWithChecksSeqReqDA_MissingSystem' does not declare ActorSystem it can be used with}}
  // expected-note@-2{{you can provide a module-wide default actor system by declaring:}}
  //
  // expected-error@-4{{distributed actor 'ProtocolWithChecksSeqReqDA_MissingSystem' does not declare ActorSystem it can be used with}}
  //
  // expected-error@-6{{type 'ProtocolWithChecksSeqReqDA_MissingSystem' does not conform to protocol 'DistributedActor'}}

  // Entire conformance is doomed, so we didn't proceed to checking the functions; that's fine
  distributed func testAT() async throws -> NotCodable { .init() }
}

// expected-error@+1{{distributed actor 'ProtocolWithChecksSeqReqDA' cannot conform to 'ProtocolWithChecksSeqReq' because of serialization requirement error in distributed instance method 'testAT()'}}
distributed actor ProtocolWithChecksSeqReqDA: ProtocolWithChecksSeqReq {
  typealias ActorSystem = FakeActorSystem
  // ok, since FakeActorSystem.SerializationRequirement == ProtocolWithChecksSeqReq.SerializationRequirement

  // expected-error@+1{{result type 'NotCodable' of distributed instance method 'testAT' does not conform to serialization requirement 'Codable'}}
  distributed func testAT() async throws -> NotCodable { .init() }
}

extension NoSerializationRequirementYet {
  // Still OK, we don't know if this will be implementable or not
  distributed func test2() -> NotCodable {
    .init()
  }
}

extension NoSerializationRequirementYet
  where SerializationRequirement == Codable {
  // expected-error@+1{{result type 'NotCodable' of distributed instance method 'test3' does not conform to serialization requirement 'Codable'}}
  distributed func test3() -> NotCodable {
    .init()
  }
}

extension NoSerializationRequirementYet
  where SerializationRequirement: Codable {
  // expected-error@+1{{result type 'NotCodable' of distributed instance method 'test4' does not conform to serialization requirement 'Codable'}}
  distributed func test4() -> NotCodable {
    .init()
  }
}

extension ProtocolWithChecksSeqReqDA {
  // expected-error@+1{{result type 'NotCodable' of distributed instance method 'test4' does not conform to serialization requirement 'Codable'}}
  distributed func test4() -> NotCodable {
    .init()
  }
}

// FIXME(distributed): remove the -verify-ignore-unknown
// <unknown>:0: error: unexpected error produced: instance method 'recordReturnType' requires that 'NotCodable' conform to 'Decodable'
// <unknown>:0: error: unexpected error produced: instance method 'recordReturnType' requires that 'NotCodable' conform to 'Encodable'
// <unknown>:0: error: unexpected error produced: instance method 'remoteCall(on:target:invocation:throwing:returning:)' requires that 'NotCodable' conform to 'Decodable'
// <unknown>:0: error: unexpected error produced: instance method 'remoteCall(on:target:invocation:throwing:returning:)' requires that 'NotCodable' conform to 'Encodable'
