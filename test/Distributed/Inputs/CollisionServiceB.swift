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

// Module `CollisionServiceB`. Same simple actor name (`Service`) and method
// name (`ping`) as `CollisionServiceA`, but a DIFFERENT `@Entitlement`. See
// CollisionServiceA.swift for the collision rationale.

import Distributed
import FakeDistributedActorSystems

@available(SwiftStdlib 6.5, *)
public distributed actor Service {
  public typealias ActorSystem = FakeRoundtripActorSystem

  @Entitlement("entitlement.B")
  public distributed func ping() -> String { "B.ping ok" }
}

// See CollisionServiceA.swift: the driver stays in-module.
@available(SwiftStdlib 6.5, *)
public func callServicePing(system: FakeRoundtripActorSystem) async throws -> String {
  let local = Service(actorSystem: system)
  let remote = try Service.resolve(id: local.id, using: system)
  return try await remote.ping()
}
