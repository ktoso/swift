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
// RemoteCallValidator and DistributedValidation.preflight), NOT the
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

distributed actor SecureHome {
  distributed func openWindow() -> String { "opened window" }

  @ValidateRemoteCall(.traceValidator)
  distributed func openDoor() -> String { "opened door" }

  @ValidateRemoteCall(.rejectAll)
  distributed func openBackDoor() -> String { "opened back door" }
}

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

// CHECK: --- done
