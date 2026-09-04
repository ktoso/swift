// RUN: %target-swift-frontend -emit-sil -enable-experimental-feature Embedded -enable-experimental-feature EmbeddedDistributed -parse-as-library -wmo -target %target-cpu-apple-macos14 %s | %FileCheck %s

// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// Verify that under Embedded mode the synthesized distributed thunk for
// `Greeter.hello` records its argument through the SINGLE generic
// `recordArgument<Value>` on the user's encoder (specialized for the concrete
// argument type), and that the thunk no longer decodes the result on the
// sender side: the old "decoder dance" is gone, so the thunk just returns the
// `Res` that `remoteCall` produced.

import _Concurrency
import Distributed

// The system binds `SerializationRequirement` to its own protocol; `String` is
// the only argument/return type used below, so that is all that must conform.
public protocol MySerializationRequirement {}
extension String: MySerializationRequirement {}

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
      where Act: DistributedActor, Act.ID == ActorID, Res: MySerializationRequirement {
    fatalError()
  }

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
}

// The synthesized distributed thunk (`Greeter.hello`'s TE) records its
// argument through the SINGLE generic `recordArgument<Value>` on the user's
// encoder, specialized for the concrete argument type (note the
// `SerializationRequirement` requirement and `Tg5` specialization suffix in the
// mangled name) - not a per-type `recordArgument(_: RemoteCallArgument<String>)`
// overload. It then calls the specialized generic `remoteCall<Act, Res>`, which
// returns `Res` directly.
//
// The old "decoder dance" is gone: the thunk no longer binds a decoder handed
// back by `remoteCall` and decodes the result itself. We assert that by
// checking there is no `decodeNextArgument` reference between the `remoteCall`
// call and the end of the thunk (that tail is exactly where the sender-side
// result decode used to live). The receiver-side `_executeDistributedTarget`
// still decodes arguments, so the check is scoped to the thunk body only.

// CHECK-LABEL: sil{{.*}} @${{.*}}GreeterC5hello4nameS2S_tYaKFTE
// CHECK: function_ref @${{.+}}MyEncoderV14recordArgument{{.*}}SerializationRequirement{{.*}}Tg5
// CHECK: function_ref @${{.+}}MySystemC10remoteCall2on6target10invocation{{.*}}Tg5
// CHECK-NOT: decodeNextArgument
// CHECK: end sil function '{{.*}}GreeterC5hello4nameS2S_tYaKFTE'
