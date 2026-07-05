// REQUIRES: swift_swift_parser, asserts
//
// UNSUPPORTED: back_deploy_concurrency
// REQUIRES: concurrency
// REQUIRES: distributed
// REQUIRES: executable_test
// REQUIRES: concurrency_runtime
// UNSUPPORTED: use_os_stdlib
// UNSUPPORTED: back_deployment_runtime
// UNSUPPORTED: freestanding
// UNSUPPORTED: OS=linux-gnu
// UNSUPPORTED: OS=linux-android
// UNSUPPORTED: OS=windows-msvc
//
// Regression test for cross-module identity collisions. Two distributed
// actors in DIFFERENT modules share the SAME simple type name (`Service`) and
// the SAME method name (`ping`), each guarded by a DIFFERENT `@Entitlement`.
//
// The previous identity scheme keyed each `swift5_daval` record on
// (FNV(simpleTypeName), FNV(simpleMethodName)), so both actors hashed to the
// same key and their validation records collided: a call to one actor could
// be validated (or wrongly accepted) against the other's entitlement. The
// current scheme keys each record on the target's full mangled distributed-
// thunk name (`RemoteCallTarget.identifier`), which is module-qualified and
// therefore distinct, so each actor enforces only its own entitlement.
//
// The just-built swiftDistributed is required (OS-shipped dylib is ABI-
// frozen). LC_LOAD_DYLIB is rewritten with install_name_tool post-link.
//
// RUN: %empty-directory(%t)
//
// Emit FakeDistributedActorSystems as a dylib so all three modules link the
// SAME FakeRoundtripActorSystem instance.
// RUN: %target-build-swift -target %target-swift-6.0-abi-triple -parse-as-library -emit-library -emit-module -module-name FakeDistributedActorSystems -o %t/%target-library-name(FakeDistributedActorSystems) %S/../Inputs/FakeDistributedActorSystems.swift
//
// Two producer modules with the same-named actor and method, different guards.
// RUN: %target-build-swift -target %target-swift-6.0-abi-triple -parse-as-library -emit-library -emit-module -module-name CollisionServiceA -plugin-path %swift-plugin-dir -I %t -L %t -lFakeDistributedActorSystems -o %t/%target-library-name(CollisionServiceA) %S/../Inputs/CollisionServiceA.swift
// RUN: %target-build-swift -target %target-swift-6.0-abi-triple -parse-as-library -emit-library -emit-module -module-name CollisionServiceB -plugin-path %swift-plugin-dir -I %t -L %t -lFakeDistributedActorSystems -o %t/%target-library-name(CollisionServiceB) %S/../Inputs/CollisionServiceB.swift
//
// Consumer: build and run the executable, linking all three dylibs.
// RUN: %target-build-swift -target %target-swift-6.0-abi-triple -parse-as-library -plugin-path %swift-plugin-dir -I %t -L %t -lFakeDistributedActorSystems -lCollisionServiceA -lCollisionServiceB -Xlinker -rpath -Xlinker %t -Xlinker -headerpad_max_install_names %s -o %t/a.out
// RUN: install_name_tool -change /usr/lib/swift/libswiftDistributed.dylib %test-resource-dir/%target-sdk-name/libswiftDistributed.dylib %t/a.out
// RUN: install_name_tool -change /usr/lib/swift/libswiftDistributed.dylib %test-resource-dir/%target-sdk-name/libswiftDistributed.dylib %t/%target-library-name(CollisionServiceA)
// RUN: install_name_tool -change /usr/lib/swift/libswiftDistributed.dylib %test-resource-dir/%target-sdk-name/libswiftDistributed.dylib %t/%target-library-name(CollisionServiceB)
// RUN: %target-codesign %t/%target-library-name(FakeDistributedActorSystems)
// RUN: %target-codesign %t/%target-library-name(CollisionServiceA)
// RUN: %target-codesign %t/%target-library-name(CollisionServiceB)
// RUN: %target-codesign %t/a.out
// RUN: %target-run %t/a.out | %FileCheck %s

import Distributed
import FakeDistributedActorSystems
import CollisionServiceA
import CollisionServiceB

typealias DefaultDistributedActorSystem = FakeRoundtripActorSystem

@available(SwiftStdlib 6.5, *)
@main
struct Main {
  static func main() async throws {
    let system = FakeRoundtripActorSystem()

    // Each actor accepts ONLY its own entitlement.
    print("--- A.ping with {entitlement.A} (accept)")
    // CHECK: --- A.ping with {entitlement.A} (accept)
    try await DistributedValidation.$currentEntitlements.withValue(["entitlement.A"]) {
      print("result=\(try await CollisionServiceA.callServicePing(system: system))")
      // CHECK: result=A.ping ok
    }

    print("--- B.ping with {entitlement.B} (accept)")
    // CHECK: --- B.ping with {entitlement.B} (accept)
    try await DistributedValidation.$currentEntitlements.withValue(["entitlement.B"]) {
      print("result=\(try await CollisionServiceB.callServicePing(system: system))")
      // CHECK: result=B.ping ok
    }

    // Collision guard: A must NOT accept B's entitlement. Under the old
    // simple-name hash scheme both `Service.ping` records collided and this
    // spuriously succeeded.
    print("--- A.ping with {entitlement.B} (must reject)")
    // CHECK: --- A.ping with {entitlement.B} (must reject)
    do {
      try await DistributedValidation.$currentEntitlements.withValue(["entitlement.B"]) {
        _ = try await CollisionServiceA.callServicePing(system: system)
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
      // CHECK-NOT: result=unexpected-success
      // CHECK: caught=Remote call rejected: missing entitlement 'entitlement.A'
    }

    print("--- B.ping with {entitlement.A} (must reject)")
    // CHECK: --- B.ping with {entitlement.A} (must reject)
    do {
      try await DistributedValidation.$currentEntitlements.withValue(["entitlement.A"]) {
        _ = try await CollisionServiceB.callServicePing(system: system)
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
      // CHECK-NOT: result=unexpected-success
      // CHECK: caught=Remote call rejected: missing entitlement 'entitlement.B'
    }

    print("--- done")
    // CHECK: --- done
  }
}
