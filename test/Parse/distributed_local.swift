// RUN: %target-typecheck-verify-swift -enable-experimental-feature DistributedActorLocalKeyword -disable-availability-checking -swift-version 6
// REQUIRES: swift_feature_DistributedActorLocalKeyword
// REQUIRES: concurrency
// REQUIRES: distributed

import Distributed

typealias DefaultDistributedActorSystem = LocalTestingDistributedActorSystem

distributed actor DA {
  distributed func hello() -> String { "hello" }
}

// ==== -----------------------------------------------------------------------
// MARK: Valid distributed(local) syntax

// Parameter position with concrete type
func validParam(da: distributed(local) DA) {}

// Parameter position with generic type
func validGeneric<T: DistributedActor>(t: distributed(local) T) {}

// ==== -----------------------------------------------------------------------
// MARK: Invalid distributed(local) syntax

// Repeated specifier
func repeated(da: distributed(local) distributed(local) DA) {} // expected-error {{parameter may have at most one 'distributed(local)' specifier}}
