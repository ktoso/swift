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

// The `distributed actor` lives in a DIFFERENT file from the actor system that
// dispatches to it. The system's `remoteCall` calls
// `greeter._executeDistributedTarget(...)`, which is compiler-synthesized onto
// this actor. See the main test file for what that pins down.

import _Concurrency
import Distributed

distributed actor Greeter {
  distributed func hello(name: String) -> String {
    return "Hello, \(name)!"
  }

  distributed func farewell(name: String) -> String {
    return "Goodbye, \(name)!"
  }
}
