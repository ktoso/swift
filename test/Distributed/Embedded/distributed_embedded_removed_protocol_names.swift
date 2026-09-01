// RUN: %target-swift-frontend -typecheck -verify -verify-ignore-unrelated -enable-experimental-feature Embedded -enable-experimental-feature EmbeddedDistributed -parse-as-library -wmo -target %target-cpu-apple-macos14 %s

// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// The embedded-specific distributed protocol names
// (`EmbeddedDistributedActorSystem` and the
// `EmbeddedDistributedTargetInvocation{Encoder,Decoder,ResultHandler}`
// family) were removed. Embedded distributed support now uses the single
// `DistributedActorSystem` protocol family; its embedded shape is
// selected by `-enable-experimental-feature Embedded` rather than by a
// separate protocol. Referencing the old names must fail with a plain
// unresolved-identifier error.
//
// The positive direction (the standard `DistributedActorSystem` family
// is usable in embedded, with the embedded-shaped members) is covered by
// distributed_embedded_basic_irgen.swift and
// distributed_embedded_source_portability.swift.

import _Concurrency
import Distributed

// expected-error@+1{{cannot find type 'EmbeddedDistributedActorSystem' in scope}}
public typealias LegacySystem = EmbeddedDistributedActorSystem

// expected-error@+1{{cannot find type 'EmbeddedDistributedTargetInvocationEncoder' in scope}}
public typealias LegacyEncoder = EmbeddedDistributedTargetInvocationEncoder

// expected-error@+1{{cannot find type 'EmbeddedDistributedTargetInvocationDecoder' in scope}}
public typealias LegacyDecoder = EmbeddedDistributedTargetInvocationDecoder

// expected-error@+1{{cannot find type 'EmbeddedDistributedTargetInvocationResultHandler' in scope}}
public typealias LegacyHandler = EmbeddedDistributedTargetInvocationResultHandler
