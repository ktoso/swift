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

// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend -target %target-cpu-apple-macos14 -enable-experimental-feature Embedded -enable-experimental-feature EmbeddedDistributed -parse-as-library %s %S/Inputs/EmbeddedFakeActorSystem.swift %S/Inputs/multifile_dispatch_actor.swift -c -o %t/a.o
// RUN: %target-embedded-link %t/a.o %target-embedded-posix-shim -o %t/a.out -L%swift_obj_root/lib/swift/embedded/%module-target-triple %target-clang-resource-dir-opt -lswift_Concurrency -lswiftDistributed %target-swift-default-executor-opt %target-embedded-concurrency-threading-shim -dead_strip
// RUN: %target-run %t/a.out | %FileCheck %s

// Also check the reverse file order: synthesis must not depend on whether the
// frontend type-checks the actor-declaring file or the actor-system file first.
// RUN: %target-swift-frontend -target %target-cpu-apple-macos14 -enable-experimental-feature Embedded -enable-experimental-feature EmbeddedDistributed -parse-as-library %s %S/Inputs/multifile_dispatch_actor.swift %S/Inputs/EmbeddedFakeActorSystem.swift -c -o %t/b.o
// RUN: %target-embedded-link %t/b.o %target-embedded-posix-shim -o %t/b.out -L%swift_obj_root/lib/swift/embedded/%module-target-triple %target-clang-resource-dir-opt -lswift_Concurrency -lswiftDistributed %target-swift-default-executor-opt %target-embedded-concurrency-threading-shim -dead_strip
// RUN: %target-run %t/b.out | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: optimized_stdlib
// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// The compiler-synthesized `_executeDistributedTarget` must be visible from a
// file OTHER than the one declaring the `distributed actor`.
//
// `_executeDistributedTarget` is a real `DistributedActor` protocol requirement
// (in the Embedded protocol shape) whose witness is produced by the derived-
// conformance machinery, the same path that derives `resolve` / `id` /
// `actorSystem` / `unownedExecutor`. Because it is a genuine witness, a
// reference from another file resolves it through normal conformance lookup, so
// synthesis does not depend on which file the frontend type-checks first.
//
// Here the reference lives in the shared Inputs/EmbeddedFakeActorSystem.swift
// (its `actorReady` captures `actor._executeDistributedTarget`), and the actor
// `Greeter` is declared in Inputs/multifile_dispatch_actor.swift - three
// separate files, with the two RUN lines swapping the system / actor file order.

import _Concurrency
import Distributed

typealias DefaultDistributedActorSystem = EmbeddedFakeRoundtripActorSystem

@main struct Main {
  static func main() async {
    let system = EmbeddedFakeRoundtripActorSystem()
    let local = Greeter(actorSystem: system)
    do {
      let remoteRef = try Greeter.resolve(id: local.id, using: system)
      // Two distinct targets, so the dispatch if-chain is exercised on both
      // the first and a later branch
      print("[swift] hello: \(try await remoteRef.hello(name: "World"))")
      print("[swift] farewell: \(try await remoteRef.farewell(name: "World"))")
    } catch {
      print("[swift] threw")
    }
  }
}

// CHECK: [swift] hello: Hello, World!
// CHECK: [swift] farewell: Goodbye, World!
