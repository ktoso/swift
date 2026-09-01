// RUN: %target-swift-frontend -emit-sil -enable-experimental-feature Embedded -parse-as-library -wmo -target %target-cpu-apple-macos14 %s | %FileCheck %s

// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// Verify that an actor with multiple distributed funcs of varying
// signatures (different param types, Void return, multi-arg) all
// type-check and produce correctly-shaped distributed thunks under
// Embedded mode. The test exercises the single generic serialization
// members specialized for `String`, `Int`, and the `Void` return that
// routes through `remoteCallVoid`.

import _Concurrency
import Distributed

// The system binds `SerializationRequirement` to its own protocol; every
// argument / return type of a distributed func must conform to it, and the
// encoder / decoder / handler serialize conforming values through a single
// generic method rather than per-type overloads
public protocol MySerializationRequirement {}
extension String: MySerializationRequirement {}
extension Int: MySerializationRequirement {}

public struct MyActorID: Sendable, Hashable {
  public let id: UInt64
}

public struct MyEncoder: DistributedTargetInvocationEncoder {
  public init() {}
  public mutating func doneRecording() throws {}
}
extension MyEncoder {
  public mutating func recordArgument<Value: MySerializationRequirement>(
      _ argument: RemoteCallArgument<Value>) throws {}
}

public struct MyDecoder: DistributedTargetInvocationDecoder {
  public init() {}
}
extension MyDecoder {
  public mutating func decodeNextArgument<Argument: MySerializationRequirement>() throws -> Argument {
    fatalError()
  }
}

public struct MyResultHandler: DistributedTargetInvocationResultHandler {
  public init() {}
  public func onReturnVoid() async throws {}
  public func onThrow(error: any Error) async throws {}
}
extension MyResultHandler {
  public func onReturn<Success: MySerializationRequirement>(_ value: Success) async throws {}
}

public final class MySystem: DistributedActorSystem, @unchecked Sendable {
  public typealias ActorID = MyActorID
  public typealias SerializationRequirement = MySerializationRequirement
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

  public func remoteCall<Act, Res>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder
  ) async throws -> Res
      where Act: DistributedActor, Act.ID == ActorID,
            Res: MySerializationRequirement { fatalError() }

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

// Each distributed func has its own TE thunk. The `_executeDistributedTarget`
// witness references these thunks, so under Embedded's CMO their linkage is
// promoted; match with or without the `hidden` keyword.
// CHECK-DAG: sil{{( hidden)?}} [thunk] [distributed]{{.*}}MultiFuncActorC5hello4nameS2S_tYaKFTE
// CHECK-DAG: sil{{( hidden)?}} [thunk] [distributed]{{.*}}MultiFuncActorC6squareyS2iYaKFTE
// CHECK-DAG: sil{{( hidden)?}} [thunk] [distributed]{{.*}}MultiFuncActorC8repeated_5countSiSS_SitYaKFTE
// CHECK-DAG: sil{{( hidden)?}} [thunk] [distributed]{{.*}}MultiFuncActorC6notifyyySSYaKFTE

// Both String and Int decode specializations of the single generic
// decodeNextArgument are emitted on MyDecoder.
// CHECK-DAG: sil{{.*}}@${{.+}}MyDecoderV18decodeNextArgument{{.+}}SerializationRequirement{{.+}}SS_Tg5
// CHECK-DAG: sil{{.*}}@${{.+}}MyDecoderV18decodeNextArgument{{.+}}SerializationRequirement{{.+}}Si_Tg5
