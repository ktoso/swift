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
// Golden-vector test pinning the FNV-1a-64 hash function used to key
// `swift5_daval` section records.
//
// Two implementations of this function exist:
//   1. `fnv1a64` in `lib/Macros/Sources/SwiftMacros/DistributedValidationMacros.swift`
//      runs at macro-expansion time to emit `actorTypeID` and `methodID`
//      literal fields into each generated section record.
//   2. `DistributedValidation.fnv1a64(of:)` in
//      `stdlib/public/Distributed/DistributedValidation.swift` runs at
//      receive-side lookup time to compute the same IDs from
//      `(_typeName(Act.self), simpleFuncName)`.
//
// If either implementation drifts, the runtime lookup silently misses and
// `@Entitlement` / `@ValidateRemoteCall` become no-ops. This test asserts the
// runtime output for a handful of fixed inputs matches hand-computed values.
// The `distributed_macro_validation_expansion.swift` test independently
// pins the macro-plugin side by CHECK-ing hex literals in emitted records
// against the same algorithm.
//
// The test binary must load the just-built swiftDistributed (which has the
// `DistributedValidation.fnv1a64` symbol), NOT the OS-shipped
// `/usr/lib/swift/libswiftDistributed.dylib` (ABI-frozen, does not have
// this symbol yet). We rewrite the LC_LOAD_DYLIB entry with
// install_name_tool after linking, matching
// `distributed_actor_remoteCall_validation.swift`.
//
// RUN: %empty-directory(%t)
// RUN: %target-build-swift -target %target-swift-6.0-abi-triple -parse-as-library -Xlinker -headerpad_max_install_names %s -o %t/a.out
// RUN: install_name_tool -change /usr/lib/swift/libswiftDistributed.dylib %test-resource-dir/%target-sdk-name/libswiftDistributed.dylib %t/a.out
// RUN: %target-codesign %t/a.out
// RUN: %target-run %t/a.out | %FileCheck %s

import Distributed

@available(SwiftStdlib 6.5, *)
func check(_ input: String, expected: UInt64) {
  let got = DistributedValidation.fnv1a64(of: input)
  if got == expected {
    print("[fnv1a64] \(input): OK")
  } else {
    print("[fnv1a64] \(input): DRIFT got=0x\(String(got, radix: 16)) expected=0x\(String(expected, radix: 16))")
  }
}

@main struct Main {
  static func main() {
    guard #available(SwiftStdlib 6.5, *) else { return }
    // Empty input: hash equals the FNV-1a-64 offset basis.
    check("", expected: 0xcbf29ce484222325)
    // CHECK: [fnv1a64] : OK

    // Single ASCII byte.
    check("a", expected: 0xaf63dc4c8601ec8c)
    // CHECK-NEXT: [fnv1a64] a: OK

    // Method name used in existing macro-expansion CHECK lines; matches
    // 0x0c2f_228d_cbee_fc75 emitted by the macro plugin.
    check("openDoor", expected: 0x0c2f228dcbeefc75)
    // CHECK-NEXT: [fnv1a64] openDoor: OK

    // Actor type name.
    check("SecureHome", expected: 0x9b04d5cfa3276967)
    // CHECK-NEXT: [fnv1a64] SecureHome: OK

    // Long input, well over the 64-byte reachable range of many hash
    // implementations; catches drift in the wrapping-multiply loop.
    check(
      "com.example.cross-module.entitlement.that-is-a-fairly-long-identifier-well-over-64-bytes-in-length-yes",
      expected: 0xe7c1191d11c9ea93)
    // CHECK-NEXT: OK

    // Composite string that appears in some section-lookup paths.
    check("SecureHome.openDoor", expected: 0x52ca2e3f63167fcf)
    // CHECK-NEXT: OK

    print("done")
    // CHECK: done
  }
}
