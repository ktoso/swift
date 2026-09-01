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
// Under Embedded Swift the `SerializationRequirement`-constrained members of
// `DistributedActorSystem` are reshaped, but the `SerializationRequirement`
// associated type itself is carried in the type system just like the
// non-embedded shape. The differences from DistributedActorSystem.swift are:
//
//   * `remoteCall` drops the `<Err>` generic parameter (errors travel as
//     `any Error`) and the `throwing:` / `returning:` metatype parameters; it
//     still returns the decoded `Res` directly, inferred from the call context.
//   * the serialization-shaped `recordArgument` / `decodeNextArgument` /
//     `onReturn` members are supplied by the concrete encoder / decoder /
//     handler as a single generic method constrained to
//     `SerializationRequirement` (rather than per-type overloads). Because
//     Embedded always specializes these call sites - a `distributed actor`
//     cannot be generic over its actor system, so the system, encoder, decoder
//     and handler are always concrete - the generic method never needs a
//     runtime witness and is emitted specialized.
//
// A `distributed actor` and its `ActorSystem: DistributedActorSystem`
// conformance clause are therefore source-portable across the two modes; only
// the transport-plumbing method bodies stay mode-specific.
@available(SwiftStdlib 5.7, *)
public protocol DistributedActorSystem: Sendable {
  /// The type used to identify distributed actors managed by this system.
  associatedtype ActorID: Sendable & Hashable

  /// The serialization requirement every argument and return type of a
  /// `distributed func` must conform to. The concrete system binds this to its
  /// own protocol (Embedded Swift cannot use `Codable`); the compiler diagnoses
  /// any argument or return type that does not conform, and the encoder /
  /// decoder / handler serialize conforming values through their generic
  /// `SerializationRequirement`-constrained members.
  associatedtype SerializationRequirement

  /// The encoder used to serialize remote calls' arguments for transport. Must
  /// expose a generic `recordArgument<Value: SerializationRequirement>(_:)`
  /// member; the compiler emits specialized calls to it from the synthesized
  /// distributed thunk.
  associatedtype InvocationEncoder: DistributedTargetInvocationEncoder

  /// The decoder used to deserialize remote calls' arguments on the receiver
  /// side, and the call's return value on the sender side. Must expose a generic
  /// `decodeNextArgument<Argument: SerializationRequirement>() -> Argument`
  /// member.
  associatedtype InvocationDecoder: DistributedTargetInvocationDecoder

  /// The result handler invoked on the receiver side once a distributed call's
  /// local execution completes. Must expose a generic
  /// `onReturn<Success: SerializationRequirement>(_:)` member.
  associatedtype ResultHandler: DistributedTargetInvocationResultHandler

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

  /// Performs a remote call and returns its decoded result.
  ///
  /// The synthesized distributed thunk:
  /// 1. Creates an encoder via `makeInvocationEncoder()`.
  /// 2. Records each argument via `encoder.recordArgument(_:)` (a specialized
  ///    call to the encoder's generic `SerializationRequirement`-constrained
  ///    member).
  /// 3. Calls `encoder.doneRecording()`.
  /// 4. Invokes `system.remoteCall(on:target:invocation:)` and returns its
  ///    result directly.
  ///
  /// Unlike the non-embedded shape there is no `throwing:` / `returning:`
  /// metatype parameter: `Res` is inferred from the call context, and the
  /// concrete system is responsible for decoding the response into `Res` inside
  /// this method (the thunk no longer receives a decoder). Errors travel as
  /// `any Error`.
  func remoteCall<Act, Res>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder
  ) async throws -> Res
    where Act: DistributedActor, Act.ActorSystem == Self
          // Res: SerializationRequirement

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
/// In Embedded Swift the concrete encoder provides a single generic
/// `recordArgument<Value: SerializationRequirement>(_:)` member (typically via
/// an extension) that serializes any conforming argument type. The compiler
/// emits specialized calls to it from the synthesized distributed thunk. The
/// return type is not recorded here: it carries no wire metadata under Embedded.
@available(SwiftStdlib 5.7, *)
public protocol DistributedTargetInvocationEncoder {
  /// Signals that all arguments have been recorded.
  mutating func doneRecording() throws

  // The record method is ad-hoc and provided by the concrete encoder:
  //
  //   mutating func recordArgument<Value: SerializationRequirement>(
  //     _ argument: RemoteCallArgument<Value>) throws
  //
  // The compiler emits specialized calls to it in the synthesized distributed
  // thunk; it is never dispatched through a runtime witness table.
}

/// Decodes a distributed call's arguments on the receiver side, and the return
/// value on the sender side.
///
/// In Embedded Swift the concrete decoder provides a single generic
/// `decodeNextArgument<Argument: SerializationRequirement>() -> Argument` member
/// (typically via an extension) that deserializes any conforming type.
@available(SwiftStdlib 5.7, *)
public protocol DistributedTargetInvocationDecoder {
  // The decode method is ad-hoc and provided by the concrete decoder:
  //
  //   mutating func decodeNextArgument<Argument: SerializationRequirement>()
  //     throws -> Argument
}

/// Invoked on the receiver side with the result of a distributed call.
///
/// In Embedded Swift the concrete handler provides a single generic
/// `onReturn<Success: SerializationRequirement>(_:)` member (typically via an
/// extension) for any conforming return type. `onReturnVoid` and `onThrow` are
/// non-generic and live directly on the protocol.
@available(SwiftStdlib 5.7, *)
public protocol DistributedTargetInvocationResultHandler {
  /// Invoked when the distributed target returns `Void`.
  func onReturnVoid() async throws

  /// Invoked when the distributed target threw an error. The error is boxed as
  /// `any Error`; there is no `<Err>` generic.
  func onThrow(error: any Error) async throws

  // The onReturn method is ad-hoc and provided by the concrete handler:
  //
  //   func onReturn<Success: SerializationRequirement>(_ value: Success)
  //     async throws
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
/// `distributed func`, decoding arguments via the decoder's generic
/// `decodeNextArgument()` member and handing the result back via `onReturn(_:)`
/// / `onReturnVoid()`. When no distributed function on the actor matches the
/// incoming target, the synthesized method throws this error.
@available(SwiftStdlib 5.7, *)
public struct EmbeddedDistributedTargetNotFound: Error, Sendable {
  public let target: String
  public init(target: String) { self.target = target }
}

#endif // $Embedded
