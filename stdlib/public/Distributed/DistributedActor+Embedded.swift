//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
import Swift
import _Concurrency

// Embedded Swift shape of the `DistributedActor` protocol.
// This is the `#if $Embedded` counterpart of the declaration in
// DistributedActor.swift; only one shape is ever compiled per build.

#if $Embedded
// Under Embedded Swift the `SerializationRequirement`-constrained members of the
// distributed actor protocols are reshaped, but the `SerializationRequirement`
// associated type itself is carried in the type system just like the
// non-embedded shape (see `DistributedActorSystem`). The concrete actor system
// binds it to its own protocol; the compiler enforces that every type appearing
// in a `distributed func` signature conforms to it, and the encoder / decoder /
// handler serialize those types through a single generic
// `SerializationRequirement`-constrained method that is always specialized.
//
// This `DistributedActor` definition is identical to the non-embedded one in
// DistributedActor.swift. The `ActorSystem: DistributedActorSystem` constraint
// is the same in both modes, which is what makes a `distributed actor`
// declaration source-portable across Embedded and non-Embedded Swift.
@available(SwiftStdlib 5.7, *)
public protocol DistributedActor: AnyObject, Sendable, Identifiable, Hashable
  where ID == ActorSystem.ActorID,
        SerializationRequirement == ActorSystem.SerializationRequirement {

  /// The type of transport used to communicate with actors of this type.
  associatedtype ActorSystem: DistributedActorSystem

  /// The serialization requirement every argument and return type of a
  /// `distributed func` on this actor must conform to. Same-typed to the actor
  /// system's `SerializationRequirement`, so the actor system's concrete choice
  /// (e.g. a user-defined byte-serialization protocol) flows through the actor.
  associatedtype SerializationRequirement

  nonisolated override var id: ID { get }
  nonisolated var actorSystem: ActorSystem { get }

  @available(SwiftStdlib 5.9, *)
  nonisolated var unownedExecutor: UnownedSerialExecutor { get }

  @available(SwiftStdlib 6.5, *)
  nonisolated(nonsending) func _executeDistributedTarget(
    target: RemoteCallTarget,
    invocationDecoder: inout Self.ActorSystem.InvocationDecoder,
    resultHandler: Self.ActorSystem.ResultHandler
  ) async throws

  static func resolve(id: ID, using system: ActorSystem) throws -> Self
}

#endif // $Embedded
