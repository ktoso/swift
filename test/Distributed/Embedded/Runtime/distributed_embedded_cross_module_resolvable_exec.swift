// RUN: %empty-directory(%t)

// Build the reusable fake actor system module.
// RUN: %target-swift-frontend -target %target-cpu-apple-macos14 -enable-experimental-feature Embedded -parse-as-library -wmo %S/Inputs/EmbeddedFakeActorSystem.swift -module-name EmbeddedFakeActorSystem -emit-module -emit-module-path %t/EmbeddedFakeActorSystem.swiftmodule -c -o %t/EmbeddedFakeActorSystem.o

// Build the `@Resolvable` API module (this compile needs the macro plugin).
// RUN: %target-swift-frontend -target %target-cpu-apple-macos14 -enable-experimental-feature Embedded -parse-as-library -wmo -plugin-path %swift-plugin-dir -I %t %S/Inputs/GreeterAPI.swift -module-name GreeterAPI -emit-module -emit-module-path %t/GreeterAPI.swiftmodule -c -o %t/GreeterAPI.o

// Build the server module (the only module naming the concrete `GreeterImpl`).
// RUN: %target-swift-frontend -target %target-cpu-apple-macos14 -enable-experimental-feature Embedded -parse-as-library -wmo -I %t %S/Inputs/GreeterServer.swift -module-name GreeterServer -emit-module -emit-module-path %t/GreeterServer.swiftmodule -c -o %t/GreeterServer.o

// Build the client / main module.
// RUN: %target-swift-frontend -target %target-cpu-apple-macos14 -enable-experimental-feature Embedded -parse-as-library -wmo -I %t %s -module-name main -c -o %t/main.o

// Link everything and run. The fake system's wire format is a raw `[UInt8]`
// treated as ASCII, so no `String` grapheme / normalization operations are
// pulled in and the Unicode data tables are not needed at link time.
// RUN: %target-embedded-link %t/EmbeddedFakeActorSystem.o %t/GreeterAPI.o %t/GreeterServer.o %t/main.o %target-embedded-posix-shim -o %t/a.out -L%swift_obj_root/lib/swift/embedded/%module-target-triple %target-clang-resource-dir-opt -lswift_Concurrency -lswiftDistributed %target-swift-default-executor-opt %target-embedded-concurrency-threading-shim -dead_strip
// RUN: %target-run %t/a.out | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: optimized_stdlib
// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// A realistic client/server split over a `@Resolvable` distributed actor
// protocol, spread across four modules, end to end:
//
//   - EmbeddedFakeActorSystem  the transport + `DistributedActorSystem`, with a
//                              by-id dispatch table (see that file)
//   - GreeterAPI               the `@Resolvable protocol Greeter`, which also
//                              generates the `$Greeter` proxy
//   - GreeterServer            the concrete `GreeterImpl` and server startup
//   - main (this file)         the CLIENT: it only ever holds a `$Greeter`
//                              proxy, resolves it by id, and calls it. It never
//                              names `GreeterImpl`.
//
// The wire-level target identifier for a call made through a `$Greeter` proxy is
// the mangled name of `$Greeter.<method>`'s thunk, NOT of the concrete actor's
// method. `GreeterImpl._executeDistributedTarget` is derived through the normal
// `DistributedActor` conformance machinery, so - even though `Greeter`/`$Greeter`
// live in a different module than `GreeterImpl` - it recognizes both the
// concrete and the `$Greeter` proxy target identifiers and routes to
// `self.<method>` either way.

import _Concurrency
import Distributed
import EmbeddedFakeActorSystem
import GreeterAPI
import GreeterServer

@main struct Main {
  static func main() async {
    let system = EmbeddedFakeRoundtripActorSystem()


    // The server sets up its local `GreeterImpl` and registers the dispatch.
    let impl = GreeterImpl(actorSystem: system)
    let id = impl.id



    do {
      // The client only has `$Greeter`: resolve a proxy by id and call it.
      // Two distinct targets, so the receive-side dispatch if-chain is
      // exercised on both the first and a later branch.
      let greeter = try $Greeter.resolve(id: id, using: system)
      print("[swift] hello: \(try await greeter.hello(name: "World"))")
      print("[swift] farewell: \(try await greeter.farewell(name: "World"))")
      // A void-returning distributed func routes through `remoteCallVoid`.
      try await greeter.note("ping")
    } catch {
      print("[swift] threw")
    }
  }
}

// CHECK:      [swift] remoteCall reached
// CHECK-NEXT: [swift] hello: Hello, World!
// CHECK:      [swift] remoteCall reached
// CHECK-NEXT: [swift] farewell: Goodbye, World!
// CHECK:      [swift] remoteCallVoid reached
// CHECK-NEXT: [swift] server noted: ping
