//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

// Shared `@Resolvable` types for the resolvable-parameter roundtrip tests.
// Compiled together with Inputs/PortableRoundtripActorSystem.swift,
// whose `PortableRoundtripActorSystem` these types bind to.
//
// The interesting part is how a distributed-actor REFERENCE crosses the wire:
// `$ResolvableWorker` (the macro-generated proxy) is serialized as its actor id,
// and decoded by RESOLVING that id back into a remote proxy through the actor
// system - the same shape a real system uses (encode the id, `resolve(id:using:)`
// on the far side). The system reaches the decoder via `PortableDecoder.system`,
// mirroring Codable's `decoder.userInfo[.actorSystemKey]`.

import _Concurrency
import Distributed

@Resolvable
public protocol ResolvableWorker: DistributedActor
    where ActorSystem == PortableRoundtripActorSystem {
  distributed func work(name: String) -> String
}

public distributed actor WorkerImpl: ResolvableWorker {
  public distributed func work(name: String) -> String {
    return "worked: \(name)"
  }
}

#if $Embedded
// Serialize the actor reference as its id; decode by resolving the id back into a stub.
extension $ResolvableWorker: PortableSerializationRequirement {
  public nonisolated func toWireBytes() -> [UInt8] {
    asciiDigits(Int(self.id.id))
  }

  public static func fromWireBytes(_ bytes: [UInt8], system: PortableRoundtripActorSystem) throws -> Self {
    let raw = parseInt(bytes[...]) ?? 0
    // `$ResolvableWorker.resolve` returns the concrete stub type;
    // The protocol requirement is the abstract `Self`, so bridge with a cast (the conforming
    // type is always this stub).
    return try $ResolvableWorker.resolve(id: PortableActorID(id: UInt64(raw)), using: system) as! Self
  }
}
#endif // $Embedded
