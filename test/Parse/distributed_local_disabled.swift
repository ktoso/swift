// RUN: %target-typecheck-verify-swift -disable-availability-checking -swift-version 6
// REQUIRES: concurrency
// REQUIRES: distributed

// Verify that without DistributedActorLocalKeyword feature flag,
// distributed(local) is NOT parsed as a type specifier

import Distributed

typealias DefaultDistributedActorSystem = LocalTestingDistributedActorSystem

distributed actor DA {}

// Without the feature flag, 'distributed(local)' is not a type specifier
// and 'distributed' is treated as a type name (which doesn't exist)
func noFeatureFlag(da: distributed(local) DA) {}
// expected-error@-1 {{cannot find type 'distributed' in scope}}
// expected-error@-2 {{expected ',' separator}}
// expected-error@-3 {{expected parameter name followed by ':'}}
