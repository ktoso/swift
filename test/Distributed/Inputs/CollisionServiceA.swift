//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

// Module `CollisionServiceA`. Declares a distributed actor whose SIMPLE name
// (`Service`) and method name (`ping`) are identical to those in module
// `CollisionServiceB`, but guards `ping` with a DIFFERENT `@Entitlement`.
//
// The old simple-name FNV identity keyed validation records on
// (hash("Service"), hash("ping")), so both modules' records collided and
// cross-talked. The full-mangled-thunk-name identity distinguishes
// `$s...17CollisionServiceA0B0C4ping...` from the `B` module's thunk.

import Distributed
import FakeDistributedActorSystems

@available(SwiftStdlib 6.5, *)
public distributed actor Service {
  public typealias ActorSystem = FakeRoundtripActorSystem

  @Entitlement("entitlement.A")
  public distributed func ping() -> String { "A.ping ok" }
}

// The driver stays in-module: creating a distributed actor and obtaining a
// remote handle is done where the actor is defined, so the consumer only
// drives it (and sets the task-local entitlements) and observes the outcome.
// The receive-side validation scan still runs in-process, so the collision is
// exercised end-to-end.
@available(SwiftStdlib 6.5, *)
public func callServicePing(system: FakeRoundtripActorSystem) async throws -> String {
  let local = Service(actorSystem: system)
  let remote = try Service.resolve(id: local.id, using: system)
  return try await remote.ping()
}
