// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend -target %target-cpu-apple-macos14 -O -enable-experimental-feature Embedded -parse-as-library -wmo %s -c -o %t/a.o
// RUN: %target-embedded-link %t/a.o %target-embedded-posix-shim -o %t/a.out -L%swift_obj_root/lib/swift/embedded/%module-target-triple %target-clang-resource-dir-opt -lswift_Concurrency -lswiftDistributed %target-swift-default-executor-opt -dead_strip
// RUN: %target-run %t/a.out | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: swift_in_compiler
// REQUIRES: optimized_stdlib
// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// Microbenchmark: measure the per-call cost of the compiler-synthesized
// `_executeDistributedTarget` if/else dispatch chain as a function of
// the number of distributed methods on the actor. Times dispatches to
// the first, middle, and last branch.
//
// This is a smoke benchmark - the absolute numbers are useful but
// noisy. The point is to surface the linear scan's growth with N and
// any nonlinearity from branch prediction / icache.

import _Concurrency
import Distributed

@_silgen_name("clock_gettime") @discardableResult
func clock_gettime(_ clk_id: Int32, _ ts: UnsafeMutablePointer<timespec>) -> Int32

public struct timespec { public var tv_sec: Int = 0; public var tv_nsec: Int = 0; public init() {} }

public struct B_ID: Sendable, Hashable {
  public let id: UInt64
  public init(id: UInt64) { self.id = id }
}

public struct B_E: EmbeddedDistributedTargetInvocationEncoder {
  public init() {}
  public mutating func doneRecording() throws {}
}
extension B_E {
  public mutating func recordReturnType(_ type: Int.Type) throws {}
}

public struct B_D: EmbeddedDistributedTargetInvocationDecoder {
  public init() {}
}
extension B_D {
  // The sender thunk's post-`remoteCall` step calls this to decode
  // the result (Int) before returning. Return a stub value
  public mutating func decodeNextArgument(_ type: Int.Type) throws -> Int { 0 }
}

public struct B_H: EmbeddedDistributedTargetInvocationResultHandler {
  public init() {}
  public func onReturnVoid() async throws {}
  public func onThrow(error: any Error) async throws { fatalError() }
}
extension B_H {
  public func onReturn(_ value: Int) async throws {}
}

public final class TargetBox: @unchecked Sendable {
  // The system's `remoteCall` stashes the wire-level target identifier
  // string here so the benchmark can replay it directly into
  // `_executeDistributedTarget` without going through the proxy each
  // iteration (we want to measure the dispatch table, not remoteCall)
  public var captured: String = ""
  public init() {}
}

public final class B_Sys: EmbeddedDistributedActorSystem, @unchecked Sendable {
  public typealias ActorID = B_ID
  public typealias InvocationEncoder = B_E
  public typealias InvocationDecoder = B_D
  public typealias ResultHandler = B_H

  let box: TargetBox
  public init(box: TargetBox) { self.box = box }

  public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
      where Act: DistributedActor, Act.ID == ActorID { nil }
  public func assignID<Act>(_ actorType: Act.Type) -> ActorID
      where Act: DistributedActor, Act.ID == ActorID { B_ID(id: 1) }
  public func actorReady<Act>(_ actor: Act)
      where Act: DistributedActor, Act.ID == ActorID {}
  public func resignID(_ id: ActorID) {}
  public func makeInvocationEncoder() -> B_E { .init() }

  public func remoteCall<Act>(
    on actor: Act, target: RemoteCallTarget, invocation: inout B_E
  ) async throws -> B_D where Act: DistributedActor, Act.ID == ActorID {
    // Stash the target identifier the sender thunk produced and return
    // an empty decoder; the caller will discard the (unused) result
    box.captured = target.identifier
    return B_D()
  }
  public func remoteCallVoid<Act>(
    on actor: Act, target: RemoteCallTarget, invocation: inout B_E
  ) async throws where Act: DistributedActor, Act.ID == ActorID {}
}

typealias DefaultDistributedActorSystem = B_Sys

// ==== ----------------------------------------------------------------------
// MARK: Actors with N distributed methods (N = 1, 4, 16, 64)
//       Each `mK` is `distributed func mK() -> Int`
// ==== ----------------------------------------------------------------------

public distributed actor Bench1 {
  public distributed func m0() -> Int { 0 }
}

public distributed actor Bench4 {
  public distributed func m0() -> Int { 0 }
  public distributed func m1() -> Int { 1 }
  public distributed func m2() -> Int { 2 }
  public distributed func m3() -> Int { 3 }
}

public distributed actor Bench16 {
  public distributed func m0() -> Int { 0 }
  public distributed func m1() -> Int { 1 }
  public distributed func m2() -> Int { 2 }
  public distributed func m3() -> Int { 3 }
  public distributed func m4() -> Int { 4 }
  public distributed func m5() -> Int { 5 }
  public distributed func m6() -> Int { 6 }
  public distributed func m7() -> Int { 7 }
  public distributed func m8() -> Int { 8 }
  public distributed func m9() -> Int { 9 }
  public distributed func m10() -> Int { 10 }
  public distributed func m11() -> Int { 11 }
  public distributed func m12() -> Int { 12 }
  public distributed func m13() -> Int { 13 }
  public distributed func m14() -> Int { 14 }
  public distributed func m15() -> Int { 15 }
}

public distributed actor Bench64 {
  public distributed func m0() -> Int { 0 }
  public distributed func m1() -> Int { 1 }
  public distributed func m2() -> Int { 2 }
  public distributed func m3() -> Int { 3 }
  public distributed func m4() -> Int { 4 }
  public distributed func m5() -> Int { 5 }
  public distributed func m6() -> Int { 6 }
  public distributed func m7() -> Int { 7 }
  public distributed func m8() -> Int { 8 }
  public distributed func m9() -> Int { 9 }
  public distributed func m10() -> Int { 10 }
  public distributed func m11() -> Int { 11 }
  public distributed func m12() -> Int { 12 }
  public distributed func m13() -> Int { 13 }
  public distributed func m14() -> Int { 14 }
  public distributed func m15() -> Int { 15 }
  public distributed func m16() -> Int { 16 }
  public distributed func m17() -> Int { 17 }
  public distributed func m18() -> Int { 18 }
  public distributed func m19() -> Int { 19 }
  public distributed func m20() -> Int { 20 }
  public distributed func m21() -> Int { 21 }
  public distributed func m22() -> Int { 22 }
  public distributed func m23() -> Int { 23 }
  public distributed func m24() -> Int { 24 }
  public distributed func m25() -> Int { 25 }
  public distributed func m26() -> Int { 26 }
  public distributed func m27() -> Int { 27 }
  public distributed func m28() -> Int { 28 }
  public distributed func m29() -> Int { 29 }
  public distributed func m30() -> Int { 30 }
  public distributed func m31() -> Int { 31 }
  public distributed func m32() -> Int { 32 }
  public distributed func m33() -> Int { 33 }
  public distributed func m34() -> Int { 34 }
  public distributed func m35() -> Int { 35 }
  public distributed func m36() -> Int { 36 }
  public distributed func m37() -> Int { 37 }
  public distributed func m38() -> Int { 38 }
  public distributed func m39() -> Int { 39 }
  public distributed func m40() -> Int { 40 }
  public distributed func m41() -> Int { 41 }
  public distributed func m42() -> Int { 42 }
  public distributed func m43() -> Int { 43 }
  public distributed func m44() -> Int { 44 }
  public distributed func m45() -> Int { 45 }
  public distributed func m46() -> Int { 46 }
  public distributed func m47() -> Int { 47 }
  public distributed func m48() -> Int { 48 }
  public distributed func m49() -> Int { 49 }
  public distributed func m50() -> Int { 50 }
  public distributed func m51() -> Int { 51 }
  public distributed func m52() -> Int { 52 }
  public distributed func m53() -> Int { 53 }
  public distributed func m54() -> Int { 54 }
  public distributed func m55() -> Int { 55 }
  public distributed func m56() -> Int { 56 }
  public distributed func m57() -> Int { 57 }
  public distributed func m58() -> Int { 58 }
  public distributed func m59() -> Int { 59 }
  public distributed func m60() -> Int { 60 }
  public distributed func m61() -> Int { 61 }
  public distributed func m62() -> Int { 62 }
  public distributed func m63() -> Int { 63 }
}

// ==== ----------------------------------------------------------------------
// MARK: Bench harness
// ==== ----------------------------------------------------------------------

@inline(never)
func now_ns() -> UInt64 {
  var ts = timespec()
  clock_gettime(0, &ts)  // CLOCK_REALTIME = 0
  return UInt64(ts.tv_sec) * 1_000_000_000 &+ UInt64(ts.tv_nsec)
}

// Run `iterations` dispatches to the captured target through
// `_executeDistributedTarget`. Returns total elapsed ns
@inline(never)
func measure(
  _ name: String,
  _ iterations: Int,
  _ run: () async -> Void
) async {
  // Warm up so the test runs at steady state (page faults, branch
  // predictor seeded, etc)
  for _ in 0..<2048 { await run() }

  let t0 = now_ns()
  for _ in 0..<iterations { await run() }
  let t1 = now_ns()

  let total = t1 &- t0
  let per_ns_x1000 = (total &* 1000) / UInt64(iterations)
  print("[bench] \(name) iters=\(iterations) total_ns=\(total) per_call_ns_x1000=\(per_ns_x1000)")
}

@main
struct Main {
  static func main() async {
    let iters = 100_000

    // ---- N=1 ----
    do {
      let box = TargetBox()
      let system = B_Sys(box: box)
      let bench = Bench1(actorSystem: system)
      let proxy = try! Bench1.resolve(id: B_ID(id: 999), using: system)
      _ = try? await proxy.m0()
      let target = RemoteCallTarget(box.captured)
      var dec = B_D()
      let handler = B_H()
      await measure("N=1 first", iters) {
        try? await bench._executeDistributedTarget(
          target: target, invocationDecoder: &dec, resultHandler: handler)
      }
    }

    // ---- N=4 ----
    do {
      let box = TargetBox()
      let system = B_Sys(box: box)
      let bench = Bench4(actorSystem: system)
      let proxy = try! Bench4.resolve(id: B_ID(id: 999), using: system)
      // First
      _ = try? await proxy.m0()
      var t_first = RemoteCallTarget(box.captured)
      _ = try? await proxy.m2()
      var t_mid = RemoteCallTarget(box.captured)
      _ = try? await proxy.m3()
      var t_last = RemoteCallTarget(box.captured)
      var dec = B_D(); let handler = B_H()
      _ = t_first; _ = t_mid; _ = t_last
      await measure("N=4 first", iters) {
        try? await bench._executeDistributedTarget(
          target: t_first, invocationDecoder: &dec, resultHandler: handler)
      }
      await measure("N=4 mid", iters) {
        try? await bench._executeDistributedTarget(
          target: t_mid, invocationDecoder: &dec, resultHandler: handler)
      }
      await measure("N=4 last", iters) {
        try? await bench._executeDistributedTarget(
          target: t_last, invocationDecoder: &dec, resultHandler: handler)
      }
    }

    // ---- N=16 ----
    do {
      let box = TargetBox()
      let system = B_Sys(box: box)
      let bench = Bench16(actorSystem: system)
      let proxy = try! Bench16.resolve(id: B_ID(id: 999), using: system)
      _ = try? await proxy.m0(); let t_first = RemoteCallTarget(box.captured)
      _ = try? await proxy.m8(); let t_mid = RemoteCallTarget(box.captured)
      _ = try? await proxy.m15(); let t_last = RemoteCallTarget(box.captured)
      var dec = B_D(); let handler = B_H()
      await measure("N=16 first", iters) {
        try? await bench._executeDistributedTarget(
          target: t_first, invocationDecoder: &dec, resultHandler: handler)
      }
      await measure("N=16 mid", iters) {
        try? await bench._executeDistributedTarget(
          target: t_mid, invocationDecoder: &dec, resultHandler: handler)
      }
      await measure("N=16 last", iters) {
        try? await bench._executeDistributedTarget(
          target: t_last, invocationDecoder: &dec, resultHandler: handler)
      }
    }

    // ---- N=64 ----
    do {
      let box = TargetBox()
      let system = B_Sys(box: box)
      let bench = Bench64(actorSystem: system)
      let proxy = try! Bench64.resolve(id: B_ID(id: 999), using: system)
      _ = try? await proxy.m0(); let t_first = RemoteCallTarget(box.captured)
      _ = try? await proxy.m32(); let t_mid = RemoteCallTarget(box.captured)
      _ = try? await proxy.m63(); let t_last = RemoteCallTarget(box.captured)
      var dec = B_D(); let handler = B_H()
      await measure("N=64 first", iters) {
        try? await bench._executeDistributedTarget(
          target: t_first, invocationDecoder: &dec, resultHandler: handler)
      }
      await measure("N=64 mid", iters) {
        try? await bench._executeDistributedTarget(
          target: t_mid, invocationDecoder: &dec, resultHandler: handler)
      }
      await measure("N=64 last", iters) {
        try? await bench._executeDistributedTarget(
          target: t_last, invocationDecoder: &dec, resultHandler: handler)
      }
    }

    print("[bench] done")
  }
}

// CHECK:      [bench] N=1 first
// CHECK:      [bench] N=4 first
// CHECK-NEXT: [bench] N=4 mid
// CHECK-NEXT: [bench] N=4 last
// CHECK:      [bench] N=16 first
// CHECK-NEXT: [bench] N=16 mid
// CHECK-NEXT: [bench] N=16 last
// CHECK:      [bench] N=64 first
// CHECK-NEXT: [bench] N=64 mid
// CHECK-NEXT: [bench] N=64 last
// CHECK:      [bench] done
