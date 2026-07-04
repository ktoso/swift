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
// End-to-end cross-module runtime test. `@Entitlement` written on distributed
// protocol requirements in the `AdminProtocol` producer module must be
// inherited onto the conforming actor's witnesses in the consumer, and the
// receive-side preflight must produce the same accept/reject outcomes as if
// the attributes had been written directly on the witnesses.
//
// This asserts SEMANTIC equivalence at runtime, not just textual expansion
// (which the `test/Distributed/Macros/distributed_macro_validation_cross_
// module_*.swift` tests cover). It exercises three policy shapes across the
// module boundary: bare-string, qualified `.anyOf`, and short-form
// implicit-member `.anyOf` (see AdminProtocol.swift for the source).
//
// The just-built swiftDistributed is required (OS-shipped dylib is ABI-
// frozen). LC_LOAD_DYLIB is rewritten with install_name_tool post-link.
//
// RUN: %empty-directory(%t)
//
// Emit FakeDistributedActorSystems as a dylib so both `AdminProtocol` and
// the client below link against the SAME instance of FakeRoundtripActorSystem
// (otherwise the two builds produce distinct `ActorAddress` / actor-system
// types that don't compare equal and the protocol conformance breaks).
// RUN: %target-build-swift -target %target-swift-6.0-abi-triple -parse-as-library -emit-library -emit-module -module-name FakeDistributedActorSystems -o %t/%target-library-name(FakeDistributedActorSystems) %S/../Inputs/FakeDistributedActorSystems.swift
//
// Producer: emit AdminProtocol as a dylib (with its .swiftmodule) so the
// client can link its protocol descriptor. This is the direct-.swiftmodule
// path; the interface-rebuild path is covered by the Macros interface test.
// RUN: %target-build-swift -target %target-swift-6.0-abi-triple -parse-as-library -emit-library -emit-module -module-name AdminProtocol -plugin-path %swift-plugin-dir -I %t -L %t -lFakeDistributedActorSystems -o %t/%target-library-name(AdminProtocol) %S/../Macros/Inputs/AdminProtocol.swift
//
// Consumer: build and run the executable, linking both shared dylibs.
// RUN: %target-build-swift -target %target-swift-6.0-abi-triple -parse-as-library -plugin-path %swift-plugin-dir -I %t -L %t -lFakeDistributedActorSystems -lAdminProtocol -Xlinker -rpath -Xlinker %t -Xlinker -headerpad_max_install_names %s -o %t/a.out
// RUN: install_name_tool -change /usr/lib/swift/libswiftDistributed.dylib %test-resource-dir/%target-sdk-name/libswiftDistributed.dylib %t/a.out
// RUN: install_name_tool -change /usr/lib/swift/libswiftDistributed.dylib %test-resource-dir/%target-sdk-name/libswiftDistributed.dylib %t/%target-library-name(AdminProtocol)
// RUN: %target-codesign %t/%target-library-name(FakeDistributedActorSystems)
// RUN: %target-codesign %t/%target-library-name(AdminProtocol)
// RUN: %target-codesign %t/a.out
// RUN: %target-run %t/a.out | %FileCheck %s

import Distributed
import FakeDistributedActorSystems
import AdminProtocol

@available(SwiftStdlib 6.5, *)
distributed actor MyHome: HomeAdmin {
  typealias ActorSystem = FakeRoundtripActorSystem

  // Witnesses carry no local attribute; the `@Entitlement` on the protocol
  // requirement is inherited by `inheritDistributedValidationAttrs` (see
  // `lib/Sema/TypeCheckDistributed.cpp`), and the peer macro emits the
  // section record on the witness.
  distributed func openDoor() -> Bool { true }
  distributed func openDoorAnyOf() -> Bool { true }
  distributed func openDoorShortAnyOf() -> Bool { true }
  distributed func openDoorCustom() -> Bool { true }
}

@available(SwiftStdlib 6.5, *)
@main
struct Main {
  static func main() async throws {
    let system = FakeRoundtripActorSystem()
    let local = MyHome(actorSystem: system)
    let remote = try MyHome.resolve(id: local.id, using: system)

    // ==== openDoor requires "com.example.cross-module" ======================
    print("--- openDoor accept")
    try await DistributedValidation.$currentEntitlements.withValue(
      ["com.example.cross-module"]
    ) {
      let v = try await remote.openDoor()
      print("result=\(v)")
    }
    // CHECK: --- openDoor accept
    // CHECK: result=true

    print("--- openDoor reject")
    do {
      try await DistributedValidation.$currentEntitlements.withValue([]) {
        _ = try await remote.openDoor()
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
    }
    // CHECK: --- openDoor reject
    // CHECK-NOT: result=unexpected-success
    // CHECK: caught=Remote call rejected: missing entitlement 'com.example.cross-module'

    // ==== openDoorAnyOf accepts either cross-module OR admin ================
    print("--- openDoorAnyOf accept via cross-module")
    try await DistributedValidation.$currentEntitlements.withValue(
      ["com.example.cross-module"]
    ) {
      let v = try await remote.openDoorAnyOf()
      print("result=\(v)")
    }
    // CHECK: --- openDoorAnyOf accept via cross-module
    // CHECK: result=true

    print("--- openDoorAnyOf accept via admin")
    try await DistributedValidation.$currentEntitlements.withValue(
      ["com.example.admin"]
    ) {
      let v = try await remote.openDoorAnyOf()
      print("result=\(v)")
    }
    // CHECK: --- openDoorAnyOf accept via admin
    // CHECK: result=true

    print("--- openDoorAnyOf reject")
    do {
      try await DistributedValidation.$currentEntitlements.withValue(
        ["com.example.something-else"]
      ) {
        _ = try await remote.openDoorAnyOf()
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
    }
    // CHECK: --- openDoorAnyOf reject
    // CHECK-NOT: result=unexpected-success
    // CHECK: caught=Remote call rejected: missing entitlement 'com.example.admin'

    // ==== openDoorShortAnyOf: bare `.anyOf(["a","b"])` short-form ==========
    print("--- openDoorShortAnyOf accept via a")
    try await DistributedValidation.$currentEntitlements.withValue(
      ["com.example.short-form-a"]
    ) {
      let v = try await remote.openDoorShortAnyOf()
      print("result=\(v)")
    }
    // CHECK: --- openDoorShortAnyOf accept via a
    // CHECK: result=true

    print("--- openDoorShortAnyOf accept via b")
    try await DistributedValidation.$currentEntitlements.withValue(
      ["com.example.short-form-b"]
    ) {
      let v = try await remote.openDoorShortAnyOf()
      print("result=\(v)")
    }
    // CHECK: --- openDoorShortAnyOf accept via b
    // CHECK: result=true

    print("--- openDoorShortAnyOf reject")
    do {
      try await DistributedValidation.$currentEntitlements.withValue([]) {
        _ = try await remote.openDoorShortAnyOf()
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
    }
    // CHECK: --- openDoorShortAnyOf reject
    // CHECK-NOT: result=unexpected-success
    // CHECK: caught=Remote call rejected: missing entitlement 'com.example.short-form-b'

    // ==== openDoorCustom: @ValidateRemoteCall(.requireCustomEntitlement) ====
    // Named factory reference inherited from the protocol requirement,
    // resolves against the producer module's extension on
    // `RemoteCallValidator` (imported transitively via `import AdminProtocol`).
    print("--- openDoorCustom accept")
    try await DistributedValidation.$currentEntitlements.withValue(
      ["com.example.custom-validator"]
    ) {
      let v = try await remote.openDoorCustom()
      print("result=\(v)")
    }
    // CHECK: --- openDoorCustom accept
    // CHECK: result=true

    print("--- openDoorCustom reject")
    do {
      try await DistributedValidation.$currentEntitlements.withValue([]) {
        _ = try await remote.openDoorCustom()
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
    }
    // CHECK: --- openDoorCustom reject
    // CHECK-NOT: result=unexpected-success
    // CHECK: caught=Remote call rejected: missing entitlement 'custom-validator'

    print("--- done")
    // CHECK: --- done
  }
}
