// RUN: %target-swift-frontend -typecheck -verify -enable-experimental-feature Embedded -enable-experimental-feature EmbeddedDistributed -parse-as-library -wmo -target %target-cpu-apple-macos14 -plugin-path %swift-plugin-dir %s

// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// 'distributed var' (computed distributed properties) are not supported in
// Embedded Swift: the synthesized receive-side dispatch table only walks
// 'distributed func' members, so a remote property read would have no matching
// dispatch branch and would fail at runtime. Diagnose the declaration up front
// rather than allowing that silent runtime failure.

import _Concurrency
import Distributed

public struct MyActorID: Sendable, Hashable {
  public let id: UInt64
}

public protocol MySerializationRequirement {}
extension String: MySerializationRequirement {}

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
    on actor: Act, target: RemoteCallTarget, invocation: inout InvocationEncoder
  ) async throws -> Res
      where Act: DistributedActor, Act.ID == ActorID,
            Res: MySerializationRequirement { fatalError() }

  public func remoteCallVoid<Act>(
    on actor: Act, target: RemoteCallTarget, invocation: inout InvocationEncoder
  ) async throws
      where Act: DistributedActor, Act.ID == ActorID { fatalError() }
}

typealias DefaultDistributedActorSystem = MySystem

distributed actor Greeter {
  // A 'distributed var' is rejected under Embedded Swift.
  // expected-error@+1{{'distributed' computed property 'name' is not supported in Embedded Swift; use a 'distributed func' instead}}
  distributed var name: String {
    "Kappa"
  }

  // A regular concrete-typed 'distributed func' still compiles fine alongside
  // the rejected property above.
  distributed func hello(name: String) -> String {
    return "Hello, \(name)!"
  }
}
