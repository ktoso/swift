// RUN: %target-swift-frontend -typecheck -verify -verify-ignore-unrelated -enable-experimental-feature Embedded -parse-as-library -wmo -target %target-cpu-apple-macos14 %s

// REQUIRES: swift_in_compiler
// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// Verify that the non-embedded distributed protocols are marked
// `@_unavailableInEmbedded` so users in embedded mode are pointed
// at `EmbeddedDistributedActorSystem` (and family) instead of the
// regular `DistributedActorSystem` (whose generic-over-
// SerializationRequirement methods can't be conformed to under
// embedded). The diagnostic fires when the type appears in
// type position; due to a Swift compiler quirk, putting an
// unavailable protocol in an inheritance clause produces only the
// missing-witness diagnostic, not the unavailable one - but for
// type-position uses (e.g. as a type alias) it fires reliably.
//
// `-verify-ignore-unrelated` skips the matching 'marked unavailable'
// notes that the compiler emits in the imported Distributed module's
// synthesized source location

import _Concurrency
import Distributed

// expected-error@+1{{'DistributedActorSystem' is unavailable: unavailable in embedded Swift}}
public typealias DAS = any DistributedActorSystem

// expected-error@+1{{'DistributedTargetInvocationEncoder' is unavailable: unavailable in embedded Swift}}
public typealias DTIE = any DistributedTargetInvocationEncoder

// expected-error@+1{{'DistributedTargetInvocationDecoder' is unavailable: unavailable in embedded Swift}}
public typealias DTID = any DistributedTargetInvocationDecoder

// expected-error@+1{{'DistributedTargetInvocationResultHandler' is unavailable: unavailable in embedded Swift}}
public typealias DTIRH = any DistributedTargetInvocationResultHandler

// The Embedded variants are available and can be used in type
// position. These declarations must compile without error.
public struct MyActorID: Sendable, Hashable {}
public struct MyEnc: EmbeddedDistributedTargetInvocationEncoder {
  public init() {}
  public mutating func doneRecording() throws {}
}
public struct MyDec: EmbeddedDistributedTargetInvocationDecoder {
  public init() {}
}
public struct MyHandler: EmbeddedDistributedTargetInvocationResultHandler {
  public init() {}
  public func onReturnVoid() async throws {}
  public func onThrow(error: any Error) async throws {}
}
