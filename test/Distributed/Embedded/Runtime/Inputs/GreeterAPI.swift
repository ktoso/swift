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

// The shared API contract, in its own module. `@Resolvable` generates the
// `$Greeter` proxy actor here; both the server (which conforms `GreeterImpl` to
// `Greeter`) and the client (which resolves and calls `$Greeter`) import this
// module. Neither the protocol nor `$Greeter` names a concrete implementation.

import Distributed
import EmbeddedFakeActorSystem

@Resolvable
public protocol Greeter: DistributedActor where ActorSystem == EmbeddedFakeRoundtripActorSystem {
  distributed func hello(name: String) -> String
  distributed func farewell(name: String) -> String
}
