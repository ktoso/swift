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
// End-to-end runtime test that observes @ValidateRemoteCall's `check`
// closure actually firing on the receive side of a distributed remote call.
//
// The test binary must load the just-built swiftDistributed (which has
// RemoteCallValidator and DistributedValidation.validate), NOT the
// OS-shipped /usr/lib/swift/libswiftDistributed.dylib (ABI-frozen, does
// not have those symbols yet). We rewrite the LC_LOAD_DYLIB entry with
// install_name_tool after linking.
//
// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems -target %target-swift-6.0-abi-triple %S/../Inputs/FakeDistributedActorSystems.swift
// RUN: %target-build-swift -target %target-swift-6.0-abi-triple -parse-as-library -plugin-path %swift-plugin-dir -I %t -Xlinker -headerpad_max_install_names %s %S/../Inputs/FakeDistributedActorSystems.swift -o %t/a.out
// RUN: install_name_tool -change /usr/lib/swift/libswiftDistributed.dylib %test-resource-dir/%target-sdk-name/libswiftDistributed.dylib %t/a.out
// RUN: %target-codesign %t/a.out
// RUN: %target-run %t/a.out | %FileCheck %s

import Distributed
import FakeDistributedActorSystems

typealias DefaultDistributedActorSystem = FakeRoundtripActorSystem

// A validator that leaves a visible trace when it fires.
@available(SwiftStdlib 6.5, *)
extension RemoteCallValidator {
  public static var traceValidator: RemoteCallValidator {
    RemoteCallValidator {
      print("[validator] check ran")
    }
  }

  public static var rejectAll: RemoteCallValidator {
    RemoteCallValidator {
      throw ValidatorRejected()
    }
  }
}

struct ValidatorRejected: Error, Codable, CustomStringConvertible {
  var description: String { "rejected by validator" }
}

@available(SwiftStdlib 6.5, *)
distributed actor SecureHome {
  distributed func openWindow() -> String { "opened window" }

  @ValidateRemoteCall(.traceValidator)
  distributed func openDoor() -> String { "opened door" }

  @ValidateRemoteCall(.rejectAll)
  distributed func openBackDoor() -> String { "opened back door" }

  // ==== Entitlement-policy coverage ==========================================
  //
  // The receive-side task-local `DistributedValidation.currentEntitlements`
  // is set below in `Main` before each call so the evaluator sees a stable
  // caller identity.

  // Single entitlement.
  @Entitlement("admin")
  distributed func adminOnly() -> String { "admin ok" }

  // `.anyOf`: succeeds if ANY leaf matches. Two leaves.
  @Entitlement(.anyOf(["a", "b"]))
  distributed func anyOfAB() -> String { "anyOf(A,B) ok" }

  // `.allOf`: succeeds only if ALL leaves match. Two leaves.
  @Entitlement(.allOf(["a", "b"]))
  distributed func allOfAB() -> String { "allOf(A,B) ok" }

  // Variadic short-form of `.anyOf` / `.allOf`: nested policies listed
  // directly, no array literal. Resolves to the `anyOf(_:)` / `allOf(_:)`
  // variadic factory, which forwards to the `.anyOf([...])` / `.allOf([...])`
  // case, so the runtime semantics are identical to the array form above.
  @Entitlement(.anyOf(.entitlement("va"), .entitlement("vb")))
  distributed func anyOfVariadic() -> String { "anyOf variadic ok" }

  @Entitlement(.allOf(.entitlement("va"), .entitlement("vb")))
  distributed func allOfVariadic() -> String { "allOf variadic ok" }

  // Nested: `.anyOf` containing `.allOf`. Accepts either {a,b together} or
  // the standalone entitlement "root".
  @Entitlement(.anyOf([.allOf(["a", "b"]), .entitlement("root")]))
  distributed func anyOfAllOfAB_or_root() -> String { "nested ok" }

  // Three-deep composition. Accepts either "root" or ({x,y together} + z).
  @Entitlement(.anyOf([
    .entitlement("root"),
    .allOf([
      .anyOf([.entitlement("x"), .entitlement("y")]),
      .entitlement("z"),
    ]),
  ]))
  distributed func deepPolicy() -> String { "deep ok" }

  // Empty collections pin the vacuous-truth semantics documented on the
  // enum cases: `.anyOf([])` rejects unconditionally,
  // `.allOf([])` accepts unconditionally.
  @Entitlement(.anyOf([]))
  distributed func alwaysReject() -> String { "unreachable" }

  @Entitlement(.allOf([]))
  distributed func alwaysAccept() -> String { "vacuous allOf ok" }
}

@available(SwiftStdlib 6.5, *)
@main
struct Main {
  static func main() async throws {
    let system = FakeRoundtripActorSystem()
    let local = SecureHome(actorSystem: system)
    // Resolve as remote so remoteCall -> executeDistributedTarget fires.
    let remote = try SecureHome.resolve(id: local.id, using: system)

    // Case 1: un-annotated method -> no validator invoked, call proceeds.
    print("--- openWindow (no annotation)")
    let a = try await remote.openWindow()
    print("result=\(a)")

    // Case 2: annotated with .traceValidator -> validator fires, call succeeds.
    print("--- openDoor (validator prints trace)")
    let b = try await remote.openDoor()
    print("result=\(b)")

    // Case 3: annotated with a rejecting validator -> throws before the
    // target method runs.
    print("--- openBackDoor (validator rejects)")
    do {
      _ = try await remote.openBackDoor()
      print("result=unexpected-success")
    } catch {
      print("caught=\(error)")
    }

    // ==== Entitlement-policy cases ==========================================
    //
    // FakeRoundtripActorSystem runs executeDistributedTarget inline in the
    // caller's task, so `$currentEntitlements.withValue([...])` propagates
    // to the receive-side validation.

    print("--- adminOnly with {\"admin\"} (accept)")
    try await DistributedValidation.$currentEntitlements.withValue(["admin"]) {
      let v = try await remote.adminOnly()
      print("result=\(v)")
    }

    print("--- adminOnly with {} (reject)")
    do {
      try await DistributedValidation.$currentEntitlements.withValue([]) {
        _ = try await remote.adminOnly()
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
    }

    print("--- anyOfAB with {\"a\"} (accept)")
    try await DistributedValidation.$currentEntitlements.withValue(["a"]) {
      let v = try await remote.anyOfAB()
      print("result=\(v)")
    }

    print("--- anyOfAB with {\"b\"} (accept)")
    try await DistributedValidation.$currentEntitlements.withValue(["b"]) {
      let v = try await remote.anyOfAB()
      print("result=\(v)")
    }

    print("--- anyOfAB with {} (reject)")
    do {
      try await DistributedValidation.$currentEntitlements.withValue([]) {
        _ = try await remote.anyOfAB()
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
    }

    print("--- allOfAB with {\"a\"} (reject)")
    do {
      try await DistributedValidation.$currentEntitlements.withValue(["a"]) {
        _ = try await remote.allOfAB()
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
    }

    print("--- allOfAB with {\"a\", \"b\"} (accept)")
    try await DistributedValidation.$currentEntitlements.withValue(["a", "b"]) {
      let v = try await remote.allOfAB()
      print("result=\(v)")
    }

    print("--- anyOfVariadic with {\"va\"} (accept)")
    try await DistributedValidation.$currentEntitlements.withValue(["va"]) {
      let v = try await remote.anyOfVariadic()
      print("result=\(v)")
    }

    print("--- anyOfVariadic with {} (reject)")
    do {
      try await DistributedValidation.$currentEntitlements.withValue([]) {
        _ = try await remote.anyOfVariadic()
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
    }

    print("--- allOfVariadic with {\"va\", \"vb\"} (accept)")
    try await DistributedValidation.$currentEntitlements.withValue(["va", "vb"]) {
      let v = try await remote.allOfVariadic()
      print("result=\(v)")
    }

    print("--- allOfVariadic with {\"va\"} (reject)")
    do {
      try await DistributedValidation.$currentEntitlements.withValue(["va"]) {
        _ = try await remote.allOfVariadic()
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
    }

    print("--- anyOfAllOfAB_or_root with {\"a\", \"b\"} (accept via allOf branch)")
    try await DistributedValidation.$currentEntitlements.withValue(["a", "b"]) {
      let v = try await remote.anyOfAllOfAB_or_root()
      print("result=\(v)")
    }

    print("--- anyOfAllOfAB_or_root with {\"root\"} (accept via root branch)")
    try await DistributedValidation.$currentEntitlements.withValue(["root"]) {
      let v = try await remote.anyOfAllOfAB_or_root()
      print("result=\(v)")
    }

    print("--- anyOfAllOfAB_or_root with {\"a\"} (reject, neither branch)")
    do {
      try await DistributedValidation.$currentEntitlements.withValue(["a"]) {
        _ = try await remote.anyOfAllOfAB_or_root()
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
    }

    print("--- deepPolicy with {\"root\"} (accept root branch)")
    try await DistributedValidation.$currentEntitlements.withValue(["root"]) {
      let v = try await remote.deepPolicy()
      print("result=\(v)")
    }

    print("--- deepPolicy with {\"x\", \"z\"} (accept via nested allOf)")
    try await DistributedValidation.$currentEntitlements.withValue(["x", "z"]) {
      let v = try await remote.deepPolicy()
      print("result=\(v)")
    }

    print("--- deepPolicy with {\"x\"} (reject, no z)")
    do {
      try await DistributedValidation.$currentEntitlements.withValue(["x"]) {
        _ = try await remote.deepPolicy()
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
    }

    print("--- alwaysReject with everything (empty anyOf is vacuously false)")
    do {
      try await DistributedValidation.$currentEntitlements.withValue(
        ["admin", "root", "a", "b", "x", "y", "z"]
      ) {
        _ = try await remote.alwaysReject()
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
    }

    print("--- alwaysAccept with {} (empty allOf is vacuously true)")
    try await DistributedValidation.$currentEntitlements.withValue([]) {
      let v = try await remote.alwaysAccept()
      print("result=\(v)")
    }

    print("--- done")
  }
}

// CHECK: --- openWindow (no annotation)
// CHECK-NOT: [validator]
// CHECK: result=opened window

// CHECK: --- openDoor (validator prints trace)
// CHECK: [validator] check ran
// CHECK: result=opened door

// CHECK: --- openBackDoor (validator rejects)
// CHECK-NOT: result=unexpected-success
// CHECK: caught=rejected by validator

// CHECK: --- adminOnly with {"admin"} (accept)
// CHECK: result=admin ok

// CHECK: --- adminOnly with {} (reject)
// CHECK-NOT: result=unexpected-success
// CHECK: caught=Remote call rejected: missing entitlement 'admin'

// CHECK: --- anyOfAB with {"a"} (accept)
// CHECK: result=anyOf(A,B) ok

// CHECK: --- anyOfAB with {"b"} (accept)
// CHECK: result=anyOf(A,B) ok

// CHECK: --- anyOfAB with {} (reject)
// CHECK-NOT: result=unexpected-success
// CHECK: caught=Remote call rejected: missing entitlement 'b'

// CHECK: --- allOfAB with {"a"} (reject)
// CHECK-NOT: result=unexpected-success
// CHECK: caught=Remote call rejected: missing entitlement 'b'

// CHECK: --- allOfAB with {"a", "b"} (accept)
// CHECK: result=allOf(A,B) ok

// CHECK: --- anyOfVariadic with {"va"} (accept)
// CHECK: result=anyOf variadic ok

// CHECK: --- anyOfVariadic with {} (reject)
// CHECK-NOT: result=unexpected-success
// CHECK: caught=Remote call rejected: missing entitlement 'vb'

// CHECK: --- allOfVariadic with {"va", "vb"} (accept)
// CHECK: result=allOf variadic ok

// CHECK: --- allOfVariadic with {"va"} (reject)
// CHECK-NOT: result=unexpected-success
// CHECK: caught=Remote call rejected: missing entitlement 'vb'

// CHECK: --- anyOfAllOfAB_or_root with {"a", "b"} (accept via allOf branch)
// CHECK: result=nested ok

// CHECK: --- anyOfAllOfAB_or_root with {"root"} (accept via root branch)
// CHECK: result=nested ok

// CHECK: --- anyOfAllOfAB_or_root with {"a"} (reject, neither branch)
// CHECK-NOT: result=unexpected-success
// CHECK: caught=Remote call rejected: missing entitlement 'root'

// CHECK: --- deepPolicy with {"root"} (accept root branch)
// CHECK: result=deep ok

// CHECK: --- deepPolicy with {"x", "z"} (accept via nested allOf)
// CHECK: result=deep ok

// CHECK: --- deepPolicy with {"x"} (reject, no z)
// CHECK-NOT: result=unexpected-success
// CHECK: caught=Remote call rejected: missing entitlement 'z'

// CHECK: --- alwaysReject with everything (empty anyOf is vacuously false)
// CHECK-NOT: result=unexpected-success
// CHECK: caught=Remote call rejected: missing entitlement '<anyOf>'

// CHECK: --- alwaysAccept with {} (empty allOf is vacuously true)
// CHECK: result=vacuous allOf ok

// CHECK: --- done
