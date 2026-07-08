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
// End-to-end runtime test that observes @ValidateRemoteCall / @Entitlement
// validation firing on the CLIENT (sender) side, from inside an actor
// system's `remoteCall` / `remoteCallVoid` implementation.
//
// The stdlib exposes `DistributedActorSystem.validate(target:context:)` as an
// opt-in primitive; the runtime never invokes it automatically. An actor
// system that wants remote-call validation calls `self.validate(...)` itself.
// The lookup is keyed on `target.identifier` (the mangled distributed-thunk
// name), so the same records fire regardless of which side (client, server,
// or both) invokes `validate`. This test's system calls it on BOTH sides for
// defense in depth and checks:
//
//   1. Un-annotated methods: no-op on both sides.
//   2. `@ValidateRemoteCall` accepting: fires on the client BEFORE the fake
//      network hop, then fires again on the server. Both sides run.
//   3. `@ValidateRemoteCall` rejecting: throws out of `remoteCall` before
//      the round trip; the server side is never reached.
//   4. `@Entitlement` rejecting: same story with the entitlement evaluator.
//   5. `@Entitlement` accepting: both sides run.
//
// The test binary must load the just-built swiftDistributed (which has
// RemoteCallValidator<AS> and DistributedActorSystem.validate), NOT the
// OS-shipped /usr/lib/swift/libswiftDistributed.dylib (ABI-frozen, does not
// have those symbols yet). We rewrite the LC_LOAD_DYLIB entry with
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

// ==== -----------------------------------------------------------------------
// MARK: Result handler (local so we don't depend on internal helpers of
// FakeDistributedActorSystems)

@available(SwiftStdlib 6.5, *)
public struct LocalResultHandler: DistributedTargetInvocationResultHandler {
  public typealias SerializationRequirement = Codable

  let storeReturn: @Sendable (Any) -> Void
  let storeError: @Sendable (Error) -> Void

  public init(storeReturn: @escaping @Sendable (Any) -> Void,
              storeError: @escaping @Sendable (Error) -> Void) {
    self.storeReturn = storeReturn
    self.storeError = storeError
  }

  public func onReturn<Success: SerializationRequirement>(value: Success) async throws {
    print(" << onReturn: \(value)")
    storeReturn(value)
  }
  public func onReturnVoid() async throws {
    print(" << onReturnVoid: ()")
    storeReturn(())
  }
  public func onThrow<Err: Error>(error: Err) async throws {
    print(" << onThrow: \(error)")
    storeError(error)
  }
}

// ==== -----------------------------------------------------------------------
// MARK: Client-side validating actor system

// An actor system that runs `self.validate` on the client side before the
// "network" hop. If validation rejects, the call never reaches
// `executeDistributedTarget` (i.e. never crosses the wire).
//
// This system reuses the invocation encoder/decoder types from
// `FakeRoundtripActorSystem` so the compiler-synthesized thunk sees a
// familiar shape; the difference is entirely in the `remoteCall`/`remoteCallVoid`
// preamble.
@available(SwiftStdlib 6.5, *)
public final class ClientValidatingActorSystem: DistributedActorSystem, @unchecked Sendable {
  public typealias ActorID = ActorAddress
  public typealias InvocationEncoder = FakeInvocationEncoder
  public typealias InvocationDecoder = FakeInvocationDecoder
  public typealias SerializationRequirement = Codable
  public typealias ResultHandler = LocalResultHandler

  var activeActors: [ActorID: any DistributedActor] = [:]
  var remoteCallResult: Any? = nil
  var remoteCallError: Error? = nil

  public init() {}

  public func resolve<Act>(id: ActorID, as actorType: Act.Type)
    throws -> Act? where Act: DistributedActor {
    print("| resolve \(id) as remote")
    return nil
  }

  public func assignID<Act>(_ actorType: Act.Type) -> ActorID
    where Act: DistributedActor {
    let id = ActorAddress(parse: "<client-validating-id>")
    print("| assign id: \(id) for \(actorType)")
    return id
  }

  public func actorReady<Act>(_ actor: Act)
    where Act: DistributedActor, Act.ID == ActorID {
    print("| actorReady: \(actor.id)")
    self.activeActors[actor.id] = actor
  }

  public func resignID(_ id: ActorID) {
    print("| resignID: \(id)")
    self.activeActors.removeValue(forKey: id)
  }

  public func makeInvocationEncoder() -> InvocationEncoder {
    .init()
  }

  public func remoteCall<Act, Err, Res>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder,
    throwing errorType: Err.Type,
    returning returnType: Res.Type
  ) async throws -> Res
    where Act: DistributedActor,
          Act.ID == ActorID,
          Err: Error,
          Res: SerializationRequirement {
    print("  >> remoteCall client-preflight: target:\(target.identifier)")
    if let lookupError = try self.validate(target: target, context: (actor.id, target)) {
      fatalError("Unexpected validation lookup error: \(lookupError)")
    }
    print("  >> remoteCall client-preflight: passed, dispatching")

    return try await roundtrip(actor: actor, target: target,
                               invocation: &invocation, returning: returnType)
  }

  public func remoteCallVoid<Act, Err>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder,
    throwing errorType: Err.Type
  ) async throws
    where Act: DistributedActor,
          Act.ID == ActorID,
          Err: Error {
    print("  >> remoteCallVoid client-preflight: target:\(target.identifier)")
    if let lookupError = try self.validate(target: target, context: (actor.id, target)) {
      fatalError("Unexpected validation lookup error: \(lookupError)")
    }
    print("  >> remoteCallVoid client-preflight: passed, dispatching")

    let _: Void = try await roundtripVoid(actor: actor, target: target,
                                          invocation: &invocation)
  }

  // ==== Shared "wire" dispatch ================================================

  private func roundtrip<Act: DistributedActor, Res: SerializationRequirement>(
    actor: Act, target: RemoteCallTarget,
    invocation: inout InvocationEncoder, returning: Res.Type
  ) async throws -> Res where Act.ID == ActorID {
    guard let targetActor = activeActors[actor.id] else {
      fatalError("Attempted remoteCall on unknown actor: \(actor.id)")
    }

    func doIt<A: DistributedActor>(active: A) async throws -> Res {
      let handler = LocalResultHandler(
        storeReturn: { self.remoteCallResult = $0; self.remoteCallError = nil },
        storeError:  { self.remoteCallResult = nil; self.remoteCallError = $0 })
      var decoder = invocation.makeDecoder()
      print("  >> [wire] executeDistributedTarget on server side")
      if let lookupError = try self.validate(target: target, context: (active.id as! ActorID, target)) {
        fatalError("Unexpected validation lookup error: \(lookupError)")
      }
      try await executeDistributedTarget(on: active, target: target,
                                         invocationDecoder: &decoder, handler: handler)
      switch (remoteCallResult, remoteCallError) {
      case (.some(let v), nil): return v as! Res
      case (nil, .some(let e)): throw e
      default: fatalError("no reply")
      }
    }
    return try await _openExistential(targetActor, do: doIt)
  }

  private func roundtripVoid<Act: DistributedActor>(
    actor: Act, target: RemoteCallTarget, invocation: inout InvocationEncoder
  ) async throws where Act.ID == ActorID {
    guard let targetActor = activeActors[actor.id] else {
      fatalError("Attempted remoteCallVoid on unknown actor: \(actor.id)")
    }
    func doIt<A: DistributedActor>(active: A) async throws {
      let handler = LocalResultHandler(
        storeReturn: { self.remoteCallResult = $0; self.remoteCallError = nil },
        storeError:  { self.remoteCallResult = nil; self.remoteCallError = $0 })
      var decoder = invocation.makeDecoder()
      print("  >> [wire] executeDistributedTarget on server side")
      if let lookupError = try self.validate(target: target, context: (active.id as! ActorID, target)) {
        fatalError("Unexpected validation lookup error: \(lookupError)")
      }
      try await executeDistributedTarget(on: active, target: target,
                                         invocationDecoder: &decoder, handler: handler)
      if let e = remoteCallError { throw e }
    }
    try await _openExistential(targetActor, do: doIt)
  }
}

// ==== -----------------------------------------------------------------------
// MARK: Validators + test actor

@available(SwiftStdlib 6.5, *)
extension RemoteCallValidator where ActorSystem == ClientValidatingActorSystem {
  public static var traceValidator: RemoteCallValidator {
    RemoteCallValidator { _ in print("[validator] check ran") }
  }
  public static var rejectAll: RemoteCallValidator {
    RemoteCallValidator { _ in throw ValidatorRejected() }
  }
}

struct ValidatorRejected: Error, Codable, CustomStringConvertible {
  var description: String { "rejected by validator" }
}

@available(SwiftStdlib 6.5, *)
typealias DefaultDistributedActorSystem = ClientValidatingActorSystem

@available(SwiftStdlib 6.5, *)
distributed actor SecureHome {
  distributed func openWindow() -> String {
    print("[server] openWindow body ran")
    return "opened window"
  }

  @ValidateRemoteCall(.traceValidator)
  distributed func openDoor() -> String {
    print("[server] openDoor body ran")
    return "opened door"
  }

  @ValidateRemoteCall(.rejectAll)
  distributed func openBackDoor() -> String {
    print("[server] openBackDoor body ran // UNREACHABLE if client-side check rejects")
    return "opened back door"
  }

  @Entitlement("admin")
  distributed func adminOnly() -> String {
    print("[server] adminOnly body ran")
    return "admin ok"
  }

  // A void-returning method exercises `remoteCallVoid`, which has its own
  // client-side hook, so we cover both call paths.
  @ValidateRemoteCall(.rejectAll)
  distributed func fireMissiles() {
    print("[server] fireMissiles body ran // UNREACHABLE if client-side check rejects")
  }
}

// ==== -----------------------------------------------------------------------
// MARK: Driver

@available(SwiftStdlib 6.5, *)
@main
struct Main {
  static func main() async throws {
    let system = ClientValidatingActorSystem()
    let local = SecureHome(actorSystem: system)
    let remote = try SecureHome.resolve(id: local.id, using: system)

    // 1. Un-annotated method: no client check, no server check, call succeeds.
    print("--- openWindow (no annotation)")
    let a = try await remote.openWindow()
    print("result=\(a)")

    // 2. `.traceValidator` accepts. Client fires the validator, then the
    // server fires it again. Two `[validator] check ran` lines expected.
    print("--- openDoor (validator accepts on both sides)")
    let b = try await remote.openDoor()
    print("result=\(b)")

    // 3. `.rejectAll` throws out of client-side `validate`. The wire step
    // is skipped and the server body never runs.
    print("--- openBackDoor (client-side rejects)")
    do {
      _ = try await remote.openBackDoor()
      print("result=unexpected-success")
    } catch {
      print("caught=\(error)")
    }

    // 4. `@Entitlement("admin")` with a missing entitlement. Client-side
    // preflight rejects; server never runs.
    print("--- adminOnly with {} (client-side rejects)")
    do {
      try await DistributedValidation.$currentEntitlements.withValue([]) {
        _ = try await remote.adminOnly()
        print("result=unexpected-success")
      }
    } catch {
      print("caught=\(error)")
    }

    // 5. `@Entitlement("admin")` with the entitlement present. Both sides
    // check and both accept; the body runs.
    print("--- adminOnly with {\"admin\"} (both sides accept)")
    try await DistributedValidation.$currentEntitlements.withValue(["admin"]) {
      let v = try await remote.adminOnly()
      print("result=\(v)")
    }

    // 6. Void return path. Client-side rejection on `remoteCallVoid`.
    print("--- fireMissiles (client-side rejects; remoteCallVoid path)")
    do {
      try await remote.fireMissiles()
      print("result=unexpected-success")
    } catch {
      print("caught=\(error)")
    }

    print("--- done")
  }
}

// ==== -----------------------------------------------------------------------
// MARK: FileCheck expectations

// 1. Un-annotated: client preflight is invoked but no validator fires; the
//    wire step runs, and the server body runs. No `[validator]` lines.
// CHECK: --- openWindow (no annotation)
// CHECK:   >> remoteCall client-preflight: target:{{.*}}openWindow{{.*}}
// CHECK:   >> remoteCall client-preflight: passed, dispatching
// CHECK-NOT: [validator]
// CHECK:   >> [wire] executeDistributedTarget on server side
// CHECK: [server] openWindow body ran
// CHECK: result=opened window

// 2. Trace validator: fires once on client (before "dispatching") and once
//    on server (inside executeDistributedTarget), then the body runs.
// CHECK: --- openDoor (validator accepts on both sides)
// CHECK:   >> remoteCall client-preflight: target:{{.*}}openDoor{{.*}}
// CHECK: [validator] check ran
// CHECK:   >> remoteCall client-preflight: passed, dispatching
// CHECK:   >> [wire] executeDistributedTarget on server side
// CHECK: [validator] check ran
// CHECK: [server] openDoor body ran
// CHECK: result=opened door

// 3. Rejecting validator: client-side throws; wire step and server body
//    must NOT run. That is the whole point of client-side validation.
// CHECK: --- openBackDoor (client-side rejects)
// CHECK:   >> remoteCall client-preflight: target:{{.*}}openBackDoor{{.*}}
// CHECK-NOT: remoteCall client-preflight: passed
// CHECK-NOT: [wire] executeDistributedTarget
// CHECK-NOT: [server] openBackDoor body ran
// CHECK-NOT: result=unexpected-success
// CHECK: caught=rejected by validator

// 4. Entitlement missing: client-side rejects; server body must not run.
// CHECK: --- adminOnly with {} (client-side rejects)
// CHECK:   >> remoteCall client-preflight: target:{{.*}}adminOnly{{.*}}
// CHECK-NOT: remoteCall client-preflight: passed
// CHECK-NOT: [wire] executeDistributedTarget
// CHECK-NOT: [server] adminOnly body ran
// CHECK-NOT: result=unexpected-success
// CHECK: caught=Remote call rejected: missing entitlement 'admin'

// 5. Entitlement present: both sides evaluate the policy; body runs.
// CHECK: --- adminOnly with {"admin"} (both sides accept)
// CHECK:   >> remoteCall client-preflight: target:{{.*}}adminOnly{{.*}}
// CHECK:   >> remoteCall client-preflight: passed, dispatching
// CHECK:   >> [wire] executeDistributedTarget on server side
// CHECK: [server] adminOnly body ran
// CHECK: result=admin ok

// 6. Void return path: remoteCallVoid preflight rejects the same way.
// CHECK: --- fireMissiles (client-side rejects; remoteCallVoid path)
// CHECK:   >> remoteCallVoid client-preflight: target:{{.*}}fireMissiles{{.*}}
// CHECK-NOT: remoteCallVoid client-preflight: passed
// CHECK-NOT: [wire] executeDistributedTarget
// CHECK-NOT: [server] fireMissiles body ran
// CHECK-NOT: result=unexpected-success
// CHECK: caught=rejected by validator

// CHECK: --- done
