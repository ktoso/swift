// RUN: %target-swift-frontend -typecheck -verify -enable-experimental-feature Embedded -parse-as-library -wmo -target %target-cpu-apple-macos14 %s

// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// A distributed actor that is generic over its actor system cannot work under
// Embedded Swift: the serialization surface is monomorphized to concrete
// per-type overloads on the system's encoder/decoder/handler, and the
// synthesized receiver-side dispatch resolves those overloads statically. A
// generic (archetype) actor system provides no such overloads, so this must be
// diagnosed up front with a clear error rather than failing later.

import _Concurrency
import Distributed

// Rejected even without any distributed members: embedded is monomorphized, so
// a generic actor system can never provide the concrete serialization surface.
// expected-error@+1{{distributed actor cannot be generic over its actor system in Embedded Swift; specify a concrete 'ActorSystem'}}
distributed actor Empty<ActorSystem> where ActorSystem: DistributedActorSystem {
}

// Rejected with a distributed member too.
// expected-error@+1{{distributed actor cannot be generic over its actor system in Embedded Swift; specify a concrete 'ActorSystem'}}
distributed actor Greeter<ActorSystem> where ActorSystem: DistributedActorSystem {
  distributed func hello() {}
}
