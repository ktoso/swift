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
// Three situations produce multiple records for the same
// `(actorTypeID, methodID)`:
//   1. Stacked attributes on the witness in source
//      (`@Entitlement("a"); @Entitlement("b") distributed func ...`).
//   2. Attribute inherited from a conformed protocol requirement while
//      the witness also carries its own attribute of a DIFFERENT kind
//      (local `@Entitlement` + inherited `@ValidateRemoteCall`, or the
//      other way round).
//   3. Attribute inherited from a conformed protocol requirement while
//      the witness also carries its own attribute of the SAME kind
//      (local `@Entitlement(A)` + inherited `@Entitlement(B)`, or two
//      `@ValidateRemoteCall`s).
//
// The compiler clones the requirement's `CustomAttr` onto the witness's
// attribute list; peer macro expansion later runs per-attribute and
// emits one record per attribute. Runtime lookup
// (`DistributedValidation.lookup`) walks all matching records and wraps
// them in a composite `RemoteCallValidator` whose `check()` runs every
// validator in section-scan order and throws on the first failure -
// AllOf semantics.
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

// Named validator factories whose closures leave a visible trace tagged
// with the factory name so we can prove both the protocol-inherited and
// witness-local checks fired.
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
  // `@ValidateRemoteCall(.traceProto)` via inheritance. Different kinds,
  // both records materialize: the entitlement check AND the trace closure
  // fire.
  @Entitlement("admin")
  distributed func inheritedAndLocal() -> String { "inherited+local ok" }
}

// ==== ------------------------------------------------------------------------
// MARK: Same-kind compose via protocol + witness — @Entitlement + @Entitlement

@available(SwiftStdlib 6.5, *)
protocol GuardedByProtocolEntitlement: DistributedActor
  where ActorSystem == FakeRoundtripActorSystem {
  @Entitlement("proto")
  distributed func compound() -> String
}

@available(SwiftStdlib 6.5, *)
distributed actor ProtocolPlusLocal: GuardedByProtocolEntitlement {
  // Both witness AND inherited attribute are `@Entitlement`. Two records
  // land in the section against `(ProtocolPlusLocal, compound)`. AllOf
  // composition requires BOTH "local" and "proto" to be granted.
  @Entitlement("local")
  distributed func compound() -> String { "compound ok" }
}

// ==== ------------------------------------------------------------------------
// MARK: Same-kind compose via protocol + witness — @ValidateRemoteCall x 2

@available(SwiftStdlib 6.5, *)
protocol GuardedByProtocolValidator: DistributedActor
  where ActorSystem == FakeRoundtripActorSystem {
  @ValidateRemoteCall(.traceProto)
  distributed func doubleValidator() -> String
}

@available(SwiftStdlib 6.5, *)
distributed actor DoubleValidatorActor: GuardedByProtocolValidator {
  // Both witness AND inherited attribute are `@ValidateRemoteCall`. Both
  // named-factory closures fire; both trace lines appear on the accept
  // path.
  @ValidateRemoteCall(.traceWitness)
  distributed func doubleValidator() -> String { "double ok" }
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
    // CHECK: --- StackedActor.both with {"first", "second"} (both accept)
    try await DistributedValidation.$currentEntitlements.withValue(
      ["first", "second"]
    ) {
      let v = try await stackedRemote.both()
      print("result=\(v)")
      // CHECK: result=both ok
    }

    print("--- StackedActor.both with {\"first\"} (missing 'second' rejects)")
    // CHECK: --- StackedActor.both with {"first"} (missing 'second' rejects)
    do {
      try await DistributedValidation.$currentEntitlements.withValue(["first"]) {
        _ = try await stackedRemote.both()
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
      // CHECK-NOT: result=unexpected-success
      // CHECK: caught=Remote call rejected: missing entitlement 'second'
    }

    print("--- StackedActor.both with {\"second\"} (missing 'first' rejects)")
    // CHECK: --- StackedActor.both with {"second"} (missing 'first' rejects)
    do {
      try await DistributedValidation.$currentEntitlements.withValue(["second"]) {
        _ = try await stackedRemote.both()
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
      // CHECK-NOT: result=unexpected-success
      // CHECK: caught=Remote call rejected: missing entitlement 'first'
    }

    // Section-scan order across records for the same key is
    // implementation-defined - only the AllOf outcome is guaranteed. This
    // case just verifies rejection; which of the two missing entitlements
    // is named in the first-thrown error is not asserted.
    print("--- StackedActor.both with {} (both missing; rejects)")
    // CHECK: --- StackedActor.both with {} (both missing; rejects)
    do {
      try await DistributedValidation.$currentEntitlements.withValue([]) {
        _ = try await stackedRemote.both()
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
      // CHECK-NOT: result=unexpected-success
      // CHECK: caught=Remote call rejected: missing entitlement
    }

    // ==== MixedActor -------------------------------------------------------
    let mixed = MixedActor(actorSystem: system)
    let mixedRemote = try MixedActor.resolve(id: mixed.id, using: system)

    // The witness trace runs alongside the entitlement check. Order of
    // section-scan across the two records is implementation-defined so
    // we just require both appear in the accept case.
    print("--- MixedActor.mixed with {\"admin\"} (both accept)")
    // CHECK: --- MixedActor.mixed with {"admin"} (both accept)
    try await DistributedValidation.$currentEntitlements.withValue(["admin"]) {
      let v = try await mixedRemote.mixed()
      print("result=\(v)")
      // CHECK-DAG: [validator] witness check ran
      // CHECK-DAG: result=mixed ok
    }

    print("--- MixedActor.mixed with {} (entitlement rejects)")
    // CHECK: --- MixedActor.mixed with {} (entitlement rejects)
    do {
      try await DistributedValidation.$currentEntitlements.withValue([]) {
        _ = try await mixedRemote.mixed()
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
      // CHECK-NOT: result=unexpected-success
      // CHECK: caught=Remote call rejected: missing entitlement 'admin'
    }

    // ==== InheritsAndAddsLocal --------------------------------------------
    let mixIn = InheritsAndAddsLocal(actorSystem: system)
    let mixInRemote = try InheritsAndAddsLocal.resolve(id: mixIn.id, using: system)

    // Both the inherited `@ValidateRemoteCall(.traceProto)` closure AND the
    // witness-local `@Entitlement("admin")` fire on the accept path.
    print("--- InheritsAndAddsLocal.inheritedAndLocal with {\"admin\"} (both accept)")
    // CHECK: --- InheritsAndAddsLocal.inheritedAndLocal with {"admin"} (both accept)
    try await DistributedValidation.$currentEntitlements.withValue(["admin"]) {
      let v = try await mixInRemote.inheritedAndLocal()
      print("result=\(v)")
      // CHECK-DAG: [validator] proto check ran
      // CHECK-DAG: result=inherited+local ok
    }

    print("--- InheritsAndAddsLocal.inheritedAndLocal with {} (witness entitlement rejects)")
    // CHECK: --- InheritsAndAddsLocal.inheritedAndLocal with {} (witness entitlement rejects)
    do {
      try await DistributedValidation.$currentEntitlements.withValue([]) {
        _ = try await mixInRemote.inheritedAndLocal()
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
      // CHECK-NOT: result=unexpected-success
      // CHECK: caught=Remote call rejected: missing entitlement 'admin'
    }

    // ==== ProtocolPlusLocal (same-kind @Entitlement + @Entitlement) --------
    let plus = ProtocolPlusLocal(actorSystem: system)
    let plusRemote = try ProtocolPlusLocal.resolve(id: plus.id, using: system)

    // Same-kind protocol + witness: both `@Entitlement`s must be granted.
    print("--- ProtocolPlusLocal.compound with {\"local\", \"proto\"} (both accept)")
    // CHECK: --- ProtocolPlusLocal.compound with {"local", "proto"} (both accept)
    try await DistributedValidation.$currentEntitlements.withValue(
      ["local", "proto"]
    ) {
      let v = try await plusRemote.compound()
      print("result=\(v)")
      // CHECK: result=compound ok
    }

    print("--- ProtocolPlusLocal.compound with {\"local\"} (missing 'proto' rejects)")
    // CHECK: --- ProtocolPlusLocal.compound with {"local"} (missing 'proto' rejects)
    do {
      try await DistributedValidation.$currentEntitlements.withValue(["local"]) {
        _ = try await plusRemote.compound()
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
      // CHECK-NOT: result=unexpected-success
      // CHECK: caught=Remote call rejected: missing entitlement 'proto'
    }

    print("--- ProtocolPlusLocal.compound with {\"proto\"} (missing 'local' rejects)")
    // CHECK: --- ProtocolPlusLocal.compound with {"proto"} (missing 'local' rejects)
    do {
      try await DistributedValidation.$currentEntitlements.withValue(["proto"]) {
        _ = try await plusRemote.compound()
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
      // CHECK-NOT: result=unexpected-success
      // CHECK: caught=Remote call rejected: missing entitlement 'local'
    }

    print("--- ProtocolPlusLocal.compound with {} (both missing; rejects)")
    // CHECK: --- ProtocolPlusLocal.compound with {} (both missing; rejects)
    do {
      try await DistributedValidation.$currentEntitlements.withValue([]) {
        _ = try await plusRemote.compound()
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
      // CHECK-NOT: result=unexpected-success
      // CHECK: caught=Remote call rejected: missing entitlement
    }

    // ==== DoubleValidatorActor (same-kind @ValidateRemoteCall x 2) ---------
    let dv = DoubleValidatorActor(actorSystem: system)
    let dvRemote = try DoubleValidatorActor.resolve(id: dv.id, using: system)

    // Same-kind protocol + witness: both `@ValidateRemoteCall` closures fire.
    print("--- DoubleValidatorActor.doubleValidator (both traces fire)")
    // CHECK: --- DoubleValidatorActor.doubleValidator (both traces fire)
    let dvr = try await dvRemote.doubleValidator()
    print("result=\(dvr)")
    // CHECK-DAG: [validator] proto check ran
    // CHECK-DAG: [validator] witness check ran
    // CHECK-DAG: result=double ok

    print("--- done")
    // CHECK: --- done
  }
}

