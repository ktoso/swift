// RUN: %target-swift-frontend -emit-sil -enable-experimental-feature Embedded -parse-as-library -wmo -target %target-cpu-apple-macos14 %s | %FileCheck %s

// REQUIRES: swift_in_compiler
// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// Verify that an actor with multiple distributed funcs of varying
// signatures (different param types, Void return, multi-arg) all
// type-check and produce correctly-shaped distributed thunks under
// Embedded mode. The test exercises the per-type overload coverage
// path for `String`, `Int`, and `Void` (i.e. `remoteCallVoid`).

import _Concurrency
import Distributed

public struct MyActorID: Sendable, Hashable {
  public let id: UInt64
}

public struct MyEncoder: EmbeddedDistributedTargetInvocationEncoder {
  public init() {}
  public mutating func doneRecording() throws {}
}
extension MyEncoder {
  public mutating func recordArgument(_ value: String, label: String) throws {}
  public mutating func recordArgument(_ value: Int,    label: String) throws {}
  public mutating func recordReturnType(_ type: String.Type) throws {}
  public mutating func recordReturnType(_ type: Int.Type) throws {}
}

public struct MyDecoder: EmbeddedDistributedTargetInvocationDecoder {
  public init() {}
}
extension MyDecoder {
  public mutating func decodeNextArgument(_: String.Type) throws -> String { "" }
  public mutating func decodeNextArgument(_: Int.Type)    throws -> Int    { 0 }
}

public struct MyResultHandler: EmbeddedDistributedTargetInvocationResultHandler {
  public init() {}
  public func onReturnVoid() async throws {}
  public func onThrow(error: any Error) async throws {}
}
extension MyResultHandler {
  public func onReturn(_ value: String) async throws {}
  public func onReturn(_ value: Int)    async throws {}
}

public final class MySystem: EmbeddedDistributedActorSystem, @unchecked Sendable {
  public typealias ActorID = MyActorID
  public typealias InvocationEncoder = MyEncoder
  public typealias InvocationDecoder = MyDecoder
  public typealias ResultHandler = MyResultHandler

  public init() {}

  public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
      where Act: DistributedActor, Act.ID == ActorID { return nil }
  public func assignID<Act>(_ actorType: Act.Type) -> ActorID
      where Act: DistributedActor, Act.ID == ActorID { return MyActorID(id: 0) }
  public func actorReady<Act>(_ actor: Act)
      where Act: DistributedActor, Act.ID == ActorID {}
  public func resignID(_ id: ActorID) {}

  public func makeInvocationEncoder() -> InvocationEncoder { .init() }

  public func remoteCall<Act>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder
  ) async throws -> InvocationDecoder
      where Act: DistributedActor, Act.ID == ActorID { fatalError() }

  public func remoteCallVoid<Act>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder
  ) async throws
      where Act: DistributedActor, Act.ID == ActorID { fatalError() }
}

typealias DefaultDistributedActorSystem = MySystem

distributed actor MultiFuncActor {
  // String -> String
  distributed func hello(name: String) -> String {
    return "Hello, \(name)!"
  }
  // Int -> Int
  distributed func square(_ x: Int) -> Int {
    return x * x
  }
  // (String, Int) -> Int  (multi-arg)
  distributed func repeated(_ s: String, count n: Int) -> Int {
    return s.count * n
  }
  // -> Void  (uses remoteCallVoid, no decode of return)
  distributed func notify(_ message: String) {
    _ = message
  }
}

// Each distributed func has its own TE thunk.
// CHECK-DAG: sil hidden [thunk] [distributed]{{.*}}MultiFuncActorC5hello4nameS2S_tYaKFTE
// CHECK-DAG: sil hidden [thunk] [distributed]{{.*}}MultiFuncActorC6squareyS2iYaKFTE
// CHECK-DAG: sil hidden [thunk] [distributed]{{.*}}MultiFuncActorC8repeated_5countSiSS_SitYaKFTE
// CHECK-DAG: sil hidden [thunk] [distributed]{{.*}}MultiFuncActorC6notifyyySSYaKFTE

// Both String and Int decode overloads are emitted on MyDecoder.
// CHECK-DAG: sil{{.*}}@${{.+}}MyDecoderV18decodeNextArgumentyS2SmKF
// CHECK-DAG: sil{{.*}}@${{.+}}MyDecoderV18decodeNextArgumentyS2imKF
