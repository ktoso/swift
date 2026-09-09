// RUN: %target-swift-frontend -typecheck -verify -enable-experimental-feature Embedded -enable-experimental-feature EmbeddedDistributed -parse-as-library -wmo -target %target-cpu-apple-macos14 %s %S/Runtime/Inputs/EmbeddedFakeActorSystem.swift

// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// Collected acceptance tests for the ways Embedded Swift deliberately LIMITS
// distributed-actor functionality. Each section pins one diagnostic that is
// emitted up front (rather than allowing a silent runtime failure later). They
// share the one embedded actor system in Runtime/Inputs/EmbeddedFakeActorSystem.swift.

import _Concurrency
import Distributed

// NOTE: this file intentionally does NOT declare a `DefaultDistributedActorSystem`
// typealias - having a default in scope suppresses the "generic over its actor
// system" diagnostic below. The non-generic actors bind their system with an
// explicit inner `typealias ActorSystem` instead.

// ==== ----------------------------------------------------------------------
// MARK: A distributed actor cannot be generic over its actor system
//
// Embedded is monomorphized: the serialization surface resolves to concrete
// members on the system's encoder/decoder/handler, and the synthesized
// receiver-side dispatch resolves them statically. A generic (archetype) actor
// system provides no such concrete surface, so this is rejected up front -
// even with no distributed members.

// expected-error@+1{{distributed actor cannot be generic over its actor system in Embedded Swift; specify a concrete 'ActorSystem'}}
distributed actor GenericEmpty<ActorSystem> where ActorSystem: DistributedActorSystem {
}

// Rejected with a distributed member too.
// expected-error@+1{{distributed actor cannot be generic over its actor system in Embedded Swift; specify a concrete 'ActorSystem'}}
distributed actor GenericGreeter<ActorSystem> where ActorSystem: DistributedActorSystem {
  distributed func hello() {}
}

// ==== ----------------------------------------------------------------------
// MARK: 'distributed var' (computed distributed properties) are not supported
//
// The synthesized receive-side dispatch table only walks 'distributed func'
// members, so a remote property read would have no matching dispatch branch and
// would fail at runtime. Diagnose the declaration instead.

distributed actor DistributedVarActor {
  typealias ActorSystem = EmbeddedFakeRoundtripActorSystem

  // expected-error@+1{{'distributed' computed properties are not supported in Embedded Swift; use a 'distributed func' instead}}
  distributed var name: String {
    "Kappa"
  }

  // A regular concrete-typed 'distributed func' still compiles fine alongside
  // the rejected property above.
  distributed func hello(name: String) -> String {
    return "Hello, \(name)!"
  }
}

// ==== ----------------------------------------------------------------------
// MARK: Argument / return types must conform to the SerializationRequirement
//
// The embedded shape carries a real `SerializationRequirement` (here
// `EmbeddedSerializationRequirement`, to which `String` conforms but the local
// `NotSerializable` deliberately does not), so a distributed func using a
// non-conforming argument or return type is rejected - the same conformance
// diagnostics normal Swift uses. The parameter check bails on the first
// offending parameter, so the parameter and result diagnostics are exercised by
// separate funcs.

struct NotSerializable: Sendable {}

distributed actor ConformanceActor {
  typealias ActorSystem = EmbeddedFakeRoundtripActorSystem

  // All argument/return types conform, so this func compiles fine.
  distributed func ok(name: String) -> String {
    return "Hello, \(name)!"
  }

  // Non-conforming parameter is rejected.
  // expected-error@+1{{parameter 'value' of type 'NotSerializable' in distributed instance method does not conform to serialization requirement 'EmbeddedSerializationRequirement'}}
  distributed func take(value: NotSerializable) {
  }

  // Conforming parameter, but a non-conforming result -> the result is rejected.
  // expected-error@+1{{result type 'NotSerializable' of distributed instance method 'make' does not conform to serialization requirement 'EmbeddedSerializationRequirement'}}
  distributed func make(from s: String) -> NotSerializable {
    return NotSerializable()
  }
}
