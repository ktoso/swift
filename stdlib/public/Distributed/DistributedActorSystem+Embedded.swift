//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
import Swift
import _Concurrency

// Embedded Swift shapes of the distributed actor system protocols.
// These are the `#if $Embedded` counterparts of the declarations in
// DistributedActorSystem.swift; only one shape is ever compiled per build.

#if $Embedded
// Under Embedded Swift the generic, `SerializationRequirement`-constrained
// members cannot be expressed, because Embedded IRGen requires every generic
// parameter to be class-bound. The embedded shape therefore drops the
// `SerializationRequirement` associated type and the `<Err>`/`<Res>` generic
// parameters on `remoteCall`; the serialization-shaped `record...` /
// `decode...` / `onReturn` methods are supplied by the user as non-generic,
// per-type overloads on the encoder / decoder / handler (see the companion
// protocols below), which the compiler resolves and verifies at compile time.
//
// This is the same `DistributedActorSystem` protocol as the non-embedded
// branch in DistributedActorSystem.swift; only the member shapes differ. A
// `distributed actor` and its `ActorSystem: DistributedActorSystem` conformance
// clause are therefore source-portable across the two modes; only the
// transport-plumbing method bodies stay mode-specific.
@available(SwiftStdlib 5.7, *)
public protocol DistributedActorSystem: Sendable {
  /// The type used to identify distributed actors managed by this system.
  associatedtype ActorID: Sendable & Hashable

  /// The encoder used to serialize remote calls' arguments and return
  /// type for transport. Must expose per-type `recordArgument(_:label:)` and
  /// `recordReturnType(_:)` overloads for every type that appears in a
  /// `distributed func` signature in the program; the compiler will diagnose
  /// missing ones.
  associatedtype InvocationEncoder: DistributedTargetInvocationEncoder

  /// The decoder used to deserialize remote calls' arguments on the receiver
  /// side, and the call's return value on the sender side. Must expose per-type
  /// `decodeNextArgument(_:)` overloads for every type that appears in a
  /// `distributed func` signature.
  associatedtype InvocationDecoder: DistributedTargetInvocationDecoder

  /// The result handler invoked on the receiver side once a distributed call's
  /// local execution completes. Must expose per-type `onReturn(_:)` overloads
  /// for every return type that appears in a `distributed func` signature in
  /// the program.
  associatedtype ResultHandler: DistributedTargetInvocationResultHandler

  // Note: there is no `associatedtype SerializationRequirement` here, unlike the
  // non-embedded protocol. Embedded Swift cannot express a generic member
  // constrained to it (every generic parameter must be class-bound), so the
  // serialization contract is not carried in the type system. Instead the user
  // supplies non-generic, per-type `recordArgument` / `decodeNextArgument` /
  // `onReturn` overloads, and the compiler checks at compile time that one
  // exists for every type used across the program's `distributed func`s

  // ==== Resolving actors by identity ------------------------------------

  /// Resolves a local or remote `ActorID` to a reference to a given
  /// distributed actor, or `nil` if a remote reference should be synthesized.
  func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
    where Act: DistributedActor, Act.ActorSystem == Self

  // ==== Actor lifecycle -------------------------------------------------

  /// Assigns an `ActorID` for a distributed actor that is being initialized
  /// locally.
  func assignID<Act>(_ actorType: Act.Type) -> ActorID
    where Act: DistributedActor, Act.ActorSystem == Self

  /// Notifies the system that a distributed actor has finished initialization
  /// and is ready to receive remote calls.
  ///
  /// Unlike the non-embedded shape, this requirement is constrained to
  /// `Act.ActorSystem == Self` rather than only `Act.ID == ActorID`. Embedded
  /// dispatch is monomorphized: to register an actor's receive entrypoint a
  /// system must be able to form a call to `actor._executeDistributedTarget`,
  /// whose decoder/handler are `Act.ActorSystem.InvocationDecoder` /
  /// `.ResultHandler`. That call only type-checks when the actor's system is
  /// known to be this one, which `Act.ActorSystem == Self` provides
  func actorReady<Act>(_ actor: Act)
    where Act: DistributedActor, Act.ActorSystem == Self

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
  /// 5. Invokes `system.remoteCall(on:target:invocation:)` and gets back an
  ///    `InvocationDecoder` populated with the response.
  /// 6. Decodes the return value via `decoder.decodeNextArgument(_:)`.
  ///
  /// Errors travel as `any Error`.
  func remoteCall<Act>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder
  ) async throws -> InvocationDecoder
    where Act: DistributedActor, Act.ActorSystem == Self

  /// Performs a remote call to a `Void`-returning distributed function.
  func remoteCallVoid<Act>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder
  ) async throws
    where Act: DistributedActor, Act.ActorSystem == Self
}

/// Encodes a distributed call's arguments for transport.
///
/// In Embedded Swift, per-type `recordArgument(_:)` overloads are provided by
/// the user (typically via extensions) for each type that appears as a
/// parameter of a `distributed func` in the program. The compiler verifies
/// the overloads are present. The return type is not recorded here: it
/// carries no wire metadata under Embedded.
@available(SwiftStdlib 5.7, *)
public protocol DistributedTargetInvocationEncoder {
  /// Signals that all arguments have been recorded.
  mutating func doneRecording() throws

  // Per-type record methods are ad-hoc and provided by the user via
  // extensions:
  //
  //   mutating func recordArgument(_ argument: RemoteCallArgument<SomeType>) throws
  //
  // The compiler emits overload-resolved calls in the synthesized distributed
  // thunk and verifies coverage at compile time
}

/// Decodes a distributed call's arguments on the receiver side, and the return
/// value on the sender side.
///
/// Per-type `decodeNextArgument(_:)` overloads are provided by the user via
/// extensions for each type that appears in a `distributed func` in the
/// program. The compiler verifies the overloads are present.
@available(SwiftStdlib 5.7, *)
public protocol DistributedTargetInvocationDecoder {
  // Per-type decode methods are ad-hoc and provided by the user via
  // extensions:
  //
  //   mutating func decodeNextArgument(_ type: SomeType.Type) throws -> SomeType
}

/// Invoked on the receiver side with the result of a distributed call.
///
/// Per-type `onReturn(_:)` overloads are provided by the user via extensions
/// for each return type that appears in a `distributed func` in the program.
/// `onReturnVoid` and `onThrow` are non-generic and live directly on the
/// protocol.
@available(SwiftStdlib 5.7, *)
public protocol DistributedTargetInvocationResultHandler {
  /// Invoked when the distributed target returns `Void`.
  func onReturnVoid() async throws

  /// Invoked when the distributed target threw an error. The error is boxed as
  /// `any Error`; there is no `<Err>` generic.
  func onThrow(error: any Error) async throws

  // Per-type onReturn methods are ad-hoc and provided by the user via
  // extensions:
  //
  //   func onReturn(_ value: SomeType) async throws
}

/// Error thrown by a distributed actor's compiler-synthesized
/// `_executeDistributedTarget(target:invocationDecoder:resultHandler:)`
/// method when the given `RemoteCallTarget` does not match any of the actor's
/// distributed functions.
///
/// The compiler synthesizes a `_executeDistributedTarget` instance method on
/// every `distributed actor` whose `ActorSystem` conforms to
/// `DistributedActorSystem` under Embedded Swift. The synthesized method
/// examines `target.identifier` and dispatches to the matching local
/// `distributed func`, decoding arguments via the user's per-type
/// `decodeNextArgument(_:)` overloads and handing the result back via
/// `onReturn(_:)` / `onReturnVoid()`. When no distributed function on the actor
/// matches the incoming target, the synthesized method throws this error.
@available(SwiftStdlib 5.7, *)
public struct EmbeddedDistributedTargetNotFound: Error, Sendable {
  public let target: String
  public init(target: String) { self.target = target }
}

#endif // $Embedded
