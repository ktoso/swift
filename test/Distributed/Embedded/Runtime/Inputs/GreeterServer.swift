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

// SERVER side, in its own module: the only place that names the concrete
// `GreeterImpl`. It conforms to the imported `@Resolvable` protocol `Greeter`,
// so its compiler-synthesized `_executeDistributedTarget` - derived through the
// normal `DistributedActor` conformance machinery, cross-module - recognizes the
// `$Greeter.<method>` proxy target identifiers the client sends and dispatches
// them to `self.<method>`.

import Distributed
import EmbeddedFakeActorSystem
import GreeterAPI

public distributed actor GreeterImpl: Greeter {
  public distributed func hello(name: String) -> String {
    return "Hello, \(name)!"
  }

  public distributed func farewell(name: String) -> String {
    return "Goodbye, \(name)!"
  }
}

