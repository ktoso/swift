// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems %S/../Inputs/FakeDistributedActorSystems.swift
// RUN: %target-build-swift -module-name main %import-libdispatch -j2 -parse-as-library -Xfrontend -disable-availability-checking -I %t %s %S/../Inputs/FakeDistributedActorSystems.swift -g -o %t/a.out
// RUN: %target-codesign %t/a.out
// RUN: %target-run %t/a.out | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: distributed
// REQUIRES: libdispatch

// rdar://76038845
// UNSUPPORTED: use_os_stdlib
// UNSUPPORTED: back_deployment_runtime

// FIXME(distributed): Distributed actors currently have some issues on windows rdar://82593574
// UNSUPPORTED: OS=windows-msvc

import Dispatch
import Distributed
import FakeDistributedActorSystems

typealias DefaultDistributedActorSystem = FakeRoundtripActorSystem

@available(SwiftStdlib 5.7, *)
public func g<T: DistributedActor>(_ t: isolated T) -> any Actor {
  return f(t)
}

//
