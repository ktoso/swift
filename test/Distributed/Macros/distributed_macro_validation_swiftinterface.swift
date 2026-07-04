// REQUIRES: swift_swift_parser, asserts
//
// UNSUPPORTED: back_deploy_concurrency
// REQUIRES: concurrency
// REQUIRES: distributed
//
// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems -target %target-swift-6.0-abi-triple %S/../Inputs/FakeDistributedActorSystems.swift
//
// Emit both the .swiftmodule and .swiftinterface for a module that declares
// a distributed protocol requirement carrying @Entitlement. The interface
// text is what a consuming module will re-parse; if @Entitlement doesn't
// appear there, cross-module inheritance breaks.
//
// RUN: %target-swift-frontend -emit-module -emit-module-path %t/AdminProtocol.swiftmodule -emit-module-interface-path %t/AdminProtocol.swiftinterface -module-name AdminProtocol -target %target-swift-6.0-abi-triple -plugin-path %swift-plugin-dir -parse-as-library -enable-library-evolution -I %t %s
// RUN: %FileCheck %s < %t/AdminProtocol.swiftinterface

import Distributed
import FakeDistributedActorSystems

@available(SwiftStdlib 6.5, *)
public protocol HomeAdmin: DistributedActor
where ActorSystem == FakeRoundtripActorSystem {
  @Entitlement("com.example.protocol-inherited")
  distributed func openDoor() -> Bool
}

// CHECK: public protocol HomeAdmin
// The @Entitlement attribute — with its full argument list — must survive
// serialization into the .swiftinterface. A consuming module re-parses the
// interface as normal Swift source, which lets our `checkDistributedActor`
// hook clone the attribute onto witnesses in that module too.
// CHECK: @Entitlement("com.example.protocol-inherited")
// CHECK-SAME: distributed func openDoor()
