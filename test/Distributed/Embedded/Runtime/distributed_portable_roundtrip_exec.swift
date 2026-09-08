// RUN: %empty-directory(%t)
//
// Ordinary (non-embedded) Swift:
// RUN: %target-build-swift -module-name main -target %target-swift-5.7-abi-triple -parse-as-library %s %S/Inputs/PortableRoundtripActorSystem.swift -o %t/plain.out
// RUN: %target-codesign %t/plain.out
// RUN: %target-run %t/plain.out | %FileCheck %s
//
// Embedded Swift:
// RUN: %target-swift-frontend -target %target-cpu-apple-macos14 -enable-experimental-feature Embedded -enable-experimental-feature EmbeddedDistributed -parse-as-library %s %S/Inputs/PortableRoundtripActorSystem.swift -c -o %t/embedded.o
// RUN: %target-embedded-link %t/embedded.o %target-embedded-posix-shim -o %t/embedded.out -L%swift_obj_root/lib/swift/embedded/%module-target-triple %target-clang-resource-dir-opt -lswift_Concurrency -lswiftDistributed %target-swift-default-executor-opt %target-embedded-concurrency-threading-shim -dead_strip
// RUN: %target-run %t/embedded.out | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: distributed
// REQUIRES: optimized_stdlib
// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// One distributed-actor round-trip source, run in BOTH modes over a real byte
// wire. The actor system - which does the actual serialize / copy-across-the-
// network / deserialize - lives in the shared Inputs file and is reused
// unchanged by both RUN blocks; only the per-value (de)serialization inside it
// differs per mode. Here the test owns just the `distributed actor`, the driver,
// and the FileCheck lines, all identical across modes.
//
// The two encodings put different bytes on the wire (JSON vs raw UTF-8), so the
// wire length is never asserted - only the decoded values are, and those match
// in both modes, which is what keeps the FileCheck lines shared.

import _Concurrency
import Distributed

distributed actor Greeter {
  distributed func hello(name: String) -> String {
    print("[swift] greeter received: \(name)")
    return "Hello, \(name)!"
  }
}

@main struct Main {
  static func main() async {
    let system = PortableRoundtripActorSystem()
    // A local greeter the system dispatches to when it receives a remote call.
    let local = Greeter(actorSystem: system)

    do {
      let remoteRef = try Greeter.resolve(id: local.id, using: system)
      let result = try await remoteRef.hello(name: "World")
      // Prints the value AFTER it was decoded from the response wire bytes -
      // proof the return value survived serialization on the way back.
      print("[swift] result: \(result)")
    } catch {
      print("[swift] threw")
    }
  }
}

// CHECK: [swift] remoteCall reached
// CHECK: [swift] greeter received: World
// CHECK: [swift] result: Hello, World!
