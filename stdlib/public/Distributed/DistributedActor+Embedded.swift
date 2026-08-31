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
// Under Embedded Swift, `DistributedActorSystem` cannot express the generic
// members constrained to a (typically non-class) `SerializationRequirement`,
// so the protocol drops the `SerializationRequirement` associated type and
// reshapes those members (see `DistributedActorSystem`). This `DistributedActor`
// definition is identical to the non-embedded one in DistributedActor.swift,
// except that it drops the `SerializationRequirement` associated type and the
// corresponding `where` clause requirement. The `ActorSystem:
// DistributedActorSystem` constraint is the same in both modes, which is what
// makes a `distributed actor` declaration source-portable across Embedded and
// non-Embedded Swift.
@available(SwiftStdlib 5.7, *)
public protocol DistributedActor: AnyObject, Sendable, Identifiable, Hashable
  where ID == ActorSystem.ActorID {

  /// The type of transport used to communicate with actors of this type.
  associatedtype ActorSystem: DistributedActorSystem

  // In Embedded Swift there is NO 'SerializationRequirement'.
  // Serialization is enforced by every supported type having an encode/decode function
  // implemented on a concrete system's encoder/decoder pair.

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
