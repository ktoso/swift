// RUN: %target-swift-frontend -emit-sil -enable-experimental-feature Embedded -enable-experimental-feature EmbeddedDistributed -parse-as-library -wmo -target %target-cpu-apple-macos14 %s | %FileCheck %s

// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// Verify the compiler synthesizes `_executeDistributedTarget(target:invocationDecoder:resultHandler:)`
// on every embedded distributed actor. Each actor's synthesized method
// dispatches over its own set of distributed funcs.

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

distributed actor Greeter {
  distributed func hello(name: String) -> String {
    return "Hello, \(name)!"
  }
  distributed func square(_ x: Int) -> Int {
    return x * x
  }
  distributed func notify(_ message: String) {
    _ = message
  }
}

// Force the synthesized `_executeDistributedTarget` to be emitted; in
// real programs the actor system's `remoteCall` calls it. Without a
// call site, dead-code elimination would drop it.
@main struct Main {
  static func main() async {
    let system = MySystem()
    let greeter = Greeter(actorSystem: system)
    var decoder = MyDecoder()
    let handler = MyResultHandler()
    let target = RemoteCallTarget("not-a-real-target")
    do {
      try await greeter._executeDistributedTarget(
          target: target,
          invocationDecoder: &decoder,
          resultHandler: handler)
    } catch {}
  }
}

// `_executeDistributedTarget` is synthesized on the actor.
// CHECK-LABEL: sil{{.*}} @${{.+}}GreeterC25_executeDistributedTarget6target17invocationDecoder13resultHandler

// The synthesized body references the single generic decode / onReturn
// members, specialized for each distributed func's concrete types (`SS_Tg5`
// for String, `Si_Tg5` for Int) - not per-type overloads.
// CHECK-DAG: function_ref @${{.+}}MyDecoderV18decodeNextArgument{{.+}}SerializationRequirement{{.+}}SS_Tg5
// CHECK-DAG: function_ref @${{.+}}MyDecoderV18decodeNextArgument{{.+}}SerializationRequirement{{.+}}Si_Tg5
// CHECK-DAG: function_ref @${{.+}}MyResultHandlerV8onReturn{{.+}}SerializationRequirement{{.+}}SS_Tg5
// CHECK-DAG: function_ref @${{.+}}MyResultHandlerV8onReturn{{.+}}SerializationRequirement{{.+}}Si_Tg5
// CHECK-DAG: function_ref @${{.+}}MyResultHandlerV12onReturnVoidyyYaKF

// And references each distributed func's distributed thunk (TE), which
// in turn handles the isRemote check and the local-vs-remote dispatch.
// CHECK-DAG: function_ref @${{.+}}GreeterC5hello4nameS2S_tYaKFTE
// CHECK-DAG: function_ref @${{.+}}GreeterC6squareyS2iYaKFTE
// CHECK-DAG: function_ref @${{.+}}GreeterC6notifyyySSYaKFTE
