// RUN: %target-swift-frontend -emit-sil -enable-experimental-feature Embedded -parse-as-library -wmo -target %target-cpu-apple-macos14 %s | %FileCheck %s

// REQUIRES: swift_in_compiler
// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// Verify that under Embedded mode the synthesized distributed thunk for
// `Greeter.hello` calls the per-type overloads on the user's concrete
// encoder/decoder/handler types (rather than going through a generic
// recordArgument<Value>/decodeNextArgument<Argument> dispatch).

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
  public mutating func recordArgument(_ argument: RemoteCallArgument<String>) throws {}
  public mutating func recordReturnType(_ type: String.Type) throws {}
}

public struct MyDecoder: EmbeddedDistributedTargetInvocationDecoder {
  public init() {}
}
extension MyDecoder {
  public mutating func decodeNextArgument(_ type: String.Type) throws -> String { "" }
}

public struct MyResultHandler: EmbeddedDistributedTargetInvocationResultHandler {
  public init() {}
  public func onReturnVoid() async throws {}
  public func onThrow(error: any Error) async throws {}
}
extension MyResultHandler {
  public func onReturn(_ value: String) async throws {}
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

distributed actor Greeter {
  distributed func hello(name: String) -> String {
    return "Hello, \(name)!"
  }
}

// The synthesized distributed thunk (`Greeter.hello`'s TE) calls the
// per-type recordArgument(_: RemoteCallArgument<String>) overload on
// the user's encoder, not a generic-over-SerializationRequirement one.
// Confirm the call site references the exact non-generic user method.

// CHECK-LABEL: sil hidden{{.*}} @${{.*}}GreeterC5hello4nameS2S_tYaKFTE
// CHECK: function_ref @${{.+}}MyEncoderV14recordArgumentyy11Distributed010RemoteCallK0VySSGKF
// CHECK: function_ref @${{.+}}MyEncoderV16recordReturnTypeyySSmKF
// CHECK: function_ref @${{.+}}MySystemC10remoteCall2on6target10invocation
// CHECK: function_ref @${{.+}}MyDecoderV18decodeNextArgumentyS2SmKF
