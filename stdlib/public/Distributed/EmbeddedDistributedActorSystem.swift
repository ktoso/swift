//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Swift
import _Concurrency

#if $Embedded

// ==== -----------------------------------------------------------------------
// MARK: EmbeddedDistributedActorSystem
//
// An alternate `DistributedActorSystem` protocol family used under
// Embedded Swift, where generic methods constrained to a non-class
// `SerializationRequirement` cannot be implemented because Embedded
// IRGen requires every generic parameter to be class-bound.
//
// The serialization-shaped methods (`recordArgument`, `recordReturnType`,
// `decodeNextArgument`, `onReturn`) are NOT declared as protocol
// requirements. Instead, users provide one **non-generic overload** per
// concrete type they actually use in a `distributed func`. The compiler
// resolves these overloads when synthesizing the distributed thunk and
// the per-actor accessor, and verifies, at WMO-end, that every type that
// appears in any `distributed func` declaration in the program has the
// required overload on the user's concrete encoder / decoder / handler.
//
// Users can add overloads via extensions in any file; the compiler
// performs the lookup against the full module:
//
//     struct MyDecoder: EmbeddedDistributedTargetInvocationDecoder { ... }
//
//     extension MyDecoder {
//       mutating func decodeNextArgument(_: String.Type) throws -> String { ... }
//       mutating func decodeNextArgument(_: Int.Type) throws -> Int { ... }
//     }
//
// New types added to a `distributed func` only require adding a new
// extension method for them, the conformance itself doesn't need to
// change.

/// A `DistributedActorSystem` variant suitable for Embedded Swift.
///
/// Distributed dispatch in Embedded Swift cannot use the generic
/// `<Argument: SerializationRequirement>` shape of the standard
/// `DistributedActorSystem` family because the non-class
/// `SerializationRequirement` cannot be propagated through generic
/// signatures under Embedded.
///
/// This protocol family instead expects the user to provide non-generic,
/// per-type overloads on its associated `InvocationEncoder`,
/// `InvocationDecoder`, and `ResultHandler` types. The compiler verifies
/// at compile time that an overload exists for every type that appears
/// in a `distributed func` signature in the program.
///
/// There is intentionally no `SerializationRequirement` associated type
/// and no `<Err>` generic parameter on `remoteCall`. Errors travel as
/// `any Error`.
public protocol EmbeddedDistributedActorSystem: Sendable {
  /// The type used to identify distributed actors managed by this system.
  associatedtype ActorID: Sendable & Hashable

  /// The encoder used to serialize remote calls' arguments and return
  /// type for transport. Must expose per-type
  /// `recordArgument(_:label:)` and `recordReturnType(_:)` overloads
  /// for every type that appears in a `distributed func` signature in
  /// the program; the compiler will diagnose missing ones.
  associatedtype InvocationEncoder: EmbeddedDistributedTargetInvocationEncoder

  /// The decoder used to deserialize remote calls' arguments on the
  /// receiver side, and the call's return value on the sender side.
  /// Must expose per-type `decodeNextArgument(_:)` overloads for every
  /// type that appears in a `distributed func` signature.
  associatedtype InvocationDecoder: EmbeddedDistributedTargetInvocationDecoder

  /// The result handler invoked on the receiver side once a distributed
  /// call's local execution completes. Must expose per-type `onReturn(_:)`
  /// overloads for every return type that appears in a `distributed func`
  /// signature in the program.
  associatedtype ResultHandler: EmbeddedDistributedTargetInvocationResultHandler

  // ==== Resolving actors by identity ------------------------------------

  /// Resolves a local or remote `ActorID` to a reference to a given
  /// distributed actor, or `nil` if a remote reference should be
  /// synthesized.
  func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
    where Act: DistributedActor, Act.ID == ActorID

  // ==== Actor lifecycle -------------------------------------------------

  /// Assigns an `ActorID` for a distributed actor that is being
  /// initialized locally.
  func assignID<Act>(_ actorType: Act.Type) -> ActorID
    where Act: DistributedActor, Act.ID == ActorID

  /// Notifies the system that a distributed actor has finished
  /// initialization and is ready to receive remote calls.
  func actorReady<Act>(_ actor: Act)
    where Act: DistributedActor, Act.ID == ActorID

  /// Notifies the system that a distributed actor is being deinitialized.
  func resignID(_ id: ActorID)

  // ==== Remote method invocations --------------------------------------

  /// Creates a fresh invocation encoder for recording a remote call.
  func makeInvocationEncoder() -> InvocationEncoder

  /// Performs a remote call.
  ///
  /// The synthesized distributed thunk:
  /// 1. Creates an encoder via `makeInvocationEncoder()`.
  /// 2. Records each argument via `encoder.recordArgument(_:label:)`
  ///    (overload-resolved per type).
  /// 3. Records the return type via `encoder.recordReturnType(_:)`.
  /// 4. Calls `encoder.doneRecording()`.
  /// 5. Invokes `system.remoteCall(on:target:invocation:)` and gets back
  ///    an `InvocationDecoder` populated with the response.
  /// 6. Decodes the return value via `decoder.decodeNextArgument(_:)`.
  ///
  /// Errors travel as `any Error`.
  func remoteCall<Act>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder
  ) async throws -> InvocationDecoder
    where Act: DistributedActor, Act.ID == ActorID

  /// Performs a remote call to a `Void`-returning distributed function.
  func remoteCallVoid<Act>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder
  ) async throws
    where Act: DistributedActor, Act.ID == ActorID
}

// ==== -----------------------------------------------------------------------
// MARK: Encoder / Decoder / ResultHandler protocols

/// Encodes a distributed call's arguments and return type for transport.
///
/// In Embedded Swift, per-type `recordArgument(_:label:)` and
/// `recordReturnType(_:)` overloads are provided by the user (typically
/// via extensions) for each type that appears in a `distributed func` in
/// the program. The compiler verifies the overloads are present.
public protocol EmbeddedDistributedTargetInvocationEncoder {
  /// Signals that all arguments and the return type have been recorded.
  mutating func doneRecording() throws

  // Per-type record methods are ad-hoc and provided by the user via
  // extensions:
  //
  //   mutating func recordArgument(_ value: SomeType, label: String) throws
  //   mutating func recordReturnType(_ type: SomeType.Type) throws
  //
  // The compiler emits overload-resolved calls in the synthesized
  // distributed thunk and verifies coverage at compile time.
}

/// Decodes a distributed call's arguments on the receiver side, and the
/// return value on the sender side.
///
/// Per-type `decodeNextArgument(_:)` overloads are provided by the user
/// via extensions for each type that appears in a `distributed func` in
/// the program. The compiler verifies the overloads are present.
public protocol EmbeddedDistributedTargetInvocationDecoder {
  // Per-type decode methods are ad-hoc and provided by the user via
  // extensions:
  //
  //   mutating func decodeNextArgument(_ type: SomeType.Type) throws -> SomeType
}

/// Invoked on the receiver side with the result of a distributed call.
///
/// Per-type `onReturn(_:)` overloads are provided by the user via
/// extensions for each return type that appears in a `distributed func`
/// in the program. `onReturnVoid` and `onThrow` are non-generic and live
/// directly on the protocol.
public protocol EmbeddedDistributedTargetInvocationResultHandler {
  /// Invoked when the distributed target returns `Void`.
  func onReturnVoid() async throws

  /// Invoked when the distributed target threw an error. The error is
  /// boxed as `any Error`; there is no `<Err>` generic.
  func onThrow(error: any Error) async throws

  // Per-type onReturn methods are ad-hoc and provided by the user via
  // extensions:
  //
  //   func onReturn(_ value: SomeType) async throws
}

// ==== -----------------------------------------------------------------------
// MARK: Receiver-side dispatch

/// Error thrown by a distributed actor's compiler-synthesized
/// `_executeDistributedTarget(target:invocationDecoder:resultHandler:)`
/// method when the given `RemoteCallTarget` does not match any of the
/// actor's distributed functions.
///
/// The compiler synthesizes a `_executeDistributedTarget` instance method
/// on every `distributed actor` whose `ActorSystem` conforms to
/// `EmbeddedDistributedActorSystem`. The synthesized method examines
/// `target.identifier` and dispatches to the matching local
/// `distributed func`, decoding arguments via the user's per-type
/// `decodeNextArgument(_:)` overloads and handing the result back via
/// `onReturn(_:)` / `onReturnVoid()`. When no distributed function on the
/// actor matches the incoming target, the synthesized method throws this
/// error.
@available(SwiftStdlib 5.7, *)
public struct EmbeddedDistributedTargetNotFound: Error, Sendable {
  public let target: String
  public init(target: String) { self.target = target }
}

#endif // $Embedded
