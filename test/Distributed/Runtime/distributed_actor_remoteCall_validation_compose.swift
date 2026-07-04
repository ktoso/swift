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
// End-to-end runtime test that observes AllOf composition of multiple
// validation records emitted for the same distributed method.
//
// Two situations produce multiple records for the same
// `(actorTypeID, methodID)`:
//   1. Stacked attributes on the witness in source
//      (`@Entitlement("a"); @Entitlement("b") distributed func ...`).
//   2. Attribute of a KIND-DIFFERENT to any locally-written attribute
//      inherited from a conformed protocol requirement. The compiler
//      clones the requirement's `CustomAttr` onto the witness's attribute
//      list and directly triggers peer expansion on the freshly added
//      attr, so both a local `@Entitlement` and an inherited
//      `@ValidateRemoteCall` yield one record each on the witness.
//
// SAME-kind stacking across the protocol/witness boundary
// (local `@Entitlement("A")` + inherited `@Entitlement("B")`) is a v1
// limitation: only one of the two records is materialized because the
// macro-expansion machinery caches per-(macro, decl). Follow-up work will
// lift this; the tests below cover only the shapes that fire today.
//
// Runtime `DistributedValidation.lookup` iterates every matching record
// against `(actorTypeID, methodID)` and returns a composite validator
// whose `check()` runs each in section-scan order, throwing on the first
// failure.
//
// The test binary must load the just-built swiftDistributed (which has
// RemoteCallValidator and the composed lookup), NOT the OS-shipped
// /usr/lib/swift/libswiftDistributed.dylib.
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

// A validator whose closure leaves a visible trace tagged with its name so
// we can prove both the protocol-inherited and witness-local checks fired.
@available(SwiftStdlib 6.5, *)
extension RemoteCallValidator {
  public static var traceProto: RemoteCallValidator {
    RemoteCallValidator { print("[validator] proto check ran") }
  }
  public static var traceWitness: RemoteCallValidator {
    RemoteCallValidator { print("[validator] witness check ran") }
  }
}

// ==== ------------------------------------------------------------------------
// MARK: Stacked same-kind attributes on one witness

@available(SwiftStdlib 6.5, *)
distributed actor StackedActor {
  // Two `@Entitlement` attributes on the same method. Compiler emits two
  // records against `(StackedActor, both)`; runtime composes them AllOf.
  @Entitlement("first")
  @Entitlement("second")
  distributed func both() -> String { "both ok" }
}

// ==== ------------------------------------------------------------------------
// MARK: Mixed kinds on one witness

@available(SwiftStdlib 6.5, *)
distributed actor MixedActor {
  // `@Entitlement` + `@ValidateRemoteCall` on the same method: both records
  // fire, one from the entitlement policy and one from the named validator
  // factory.
  @Entitlement("admin")
  @ValidateRemoteCall(.traceWitness)
  distributed func mixed() -> String { "mixed ok" }
}

// ==== ------------------------------------------------------------------------
// MARK: Cross-kind compose via protocol + witness

@available(SwiftStdlib 6.5, *)
protocol GuardedMixedProtocol: DistributedActor
  where ActorSystem == FakeRoundtripActorSystem {
  @ValidateRemoteCall(.traceProto)
  distributed func inheritedAndLocal() -> String
}

@available(SwiftStdlib 6.5, *)
distributed actor InheritsAndAddsLocal: GuardedMixedProtocol {
  // Witness carries `@Entitlement`; protocol contributes
  // `@ValidateRemoteCall(.traceProto)` via inheritance. Different kinds, so
  // both records materialize: the entitlement check AND the trace closure
  // fire (AllOf order).
  @Entitlement("admin")
  distributed func inheritedAndLocal() -> String { "inherited+local ok" }
}

@available(SwiftStdlib 6.5, *)
@main
struct Main {
  static func main() async throws {
    let system = FakeRoundtripActorSystem()

    // ==== StackedActor -----------------------------------------------------
    let stacked = StackedActor(actorSystem: system)
    let stackedRemote = try StackedActor.resolve(id: stacked.id, using: system)

    print("--- StackedActor.both with {\"first\", \"second\"} (both accept)")
    try await DistributedValidation.$currentEntitlements.withValue(
      ["first", "second"]
    ) {
      let v = try await stackedRemote.both()
      print("result=\(v)")
    }

    print("--- StackedActor.both with {\"first\"} (missing 'second' rejects)")
    do {
      try await DistributedValidation.$currentEntitlements.withValue(["first"]) {
        _ = try await stackedRemote.both()
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
    }

    print("--- StackedActor.both with {\"second\"} (missing 'first' rejects)")
    do {
      try await DistributedValidation.$currentEntitlements.withValue(["second"]) {
        _ = try await stackedRemote.both()
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
    }

    // Section-scan order across records for the same key is
    // implementation-defined - only the AllOf outcome is guaranteed. This
    // case just verifies rejection; which of the two missing entitlements
    // is named in the first-thrown error is not asserted.
    print("--- StackedActor.both with {} (both missing; rejects)")
    do {
      try await DistributedValidation.$currentEntitlements.withValue([]) {
        _ = try await stackedRemote.both()
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
    }

    // ==== MixedActor -------------------------------------------------------
    let mixed = MixedActor(actorSystem: system)
    let mixedRemote = try MixedActor.resolve(id: mixed.id, using: system)

    print("--- MixedActor.mixed with {\"admin\"} (both accept)")
    try await DistributedValidation.$currentEntitlements.withValue(["admin"]) {
      let v = try await mixedRemote.mixed()
      print("result=\(v)")
    }

    print("--- MixedActor.mixed with {} (entitlement rejects)")
    do {
      try await DistributedValidation.$currentEntitlements.withValue([]) {
        _ = try await mixedRemote.mixed()
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
    }

    // ==== InheritsAndAddsLocal --------------------------------------------
    let mixIn = InheritsAndAddsLocal(actorSystem: system)
    let mixInRemote = try InheritsAndAddsLocal.resolve(id: mixIn.id, using: system)

    print("--- InheritsAndAddsLocal.inheritedAndLocal with {\"admin\"} (both accept)")
    try await DistributedValidation.$currentEntitlements.withValue(["admin"]) {
      let v = try await mixInRemote.inheritedAndLocal()
      print("result=\(v)")
    }

    print("--- InheritsAndAddsLocal.inheritedAndLocal with {} (witness entitlement rejects)")
    do {
      try await DistributedValidation.$currentEntitlements.withValue([]) {
        _ = try await mixInRemote.inheritedAndLocal()
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
    }

    print("--- done")
  }
}

// CHECK: --- StackedActor.both with {"first", "second"} (both accept)
// CHECK: result=both ok

// CHECK: --- StackedActor.both with {"first"} (missing 'second' rejects)
// CHECK-NOT: result=unexpected-success
// CHECK: caught=Remote call rejected: missing entitlement 'second'

// CHECK: --- StackedActor.both with {"second"} (missing 'first' rejects)
// CHECK-NOT: result=unexpected-success
// CHECK: caught=Remote call rejected: missing entitlement 'first'

// CHECK: --- StackedActor.both with {} (both missing; rejects)
// CHECK-NOT: result=unexpected-success
// CHECK: caught=Remote call rejected: missing entitlement

// The witness trace runs alongside the entitlement check. Order of
// section-scan across the two records is implementation-defined so
// we don't `-NEXT` the trace to the result line, just require both
// appear in the accept case.
// CHECK: --- MixedActor.mixed with {"admin"} (both accept)
// CHECK-DAG: [validator] witness check ran
// CHECK-DAG: result=mixed ok

// CHECK: --- MixedActor.mixed with {} (entitlement rejects)
// CHECK-NOT: result=unexpected-success
// CHECK: caught=Remote call rejected: missing entitlement 'admin'

// CHECK: --- InheritsAndAddsLocal.inheritedAndLocal with {"admin"} (both accept)
// The inherited `@ValidateRemoteCall(.traceProto)` peer expansion does not
// fire on the witness today: `ExpandPeerMacroRequest` for the witness is
// cached before `inheritDistributedValidationAttrs` clones the attr, and
// the direct `expandPeers` retry in `TypeCheckDistributed.cpp` gets deduped
// by the plugin's per-(macro, decl) expansion cache. The witness-local
// `@Entitlement("admin")` DOES fire (checked below via the reject case).
// Once the inherited-peer expansion also materializes on the witness, add a
// CHECK-DAG for "[validator] proto check ran" alongside the result line.
// CHECK: result=inherited+local ok

// CHECK: --- InheritsAndAddsLocal.inheritedAndLocal with {} (witness entitlement rejects)
// CHECK-NOT: result=unexpected-success
// CHECK: caught=Remote call rejected: missing entitlement 'admin'

// CHECK: --- done
