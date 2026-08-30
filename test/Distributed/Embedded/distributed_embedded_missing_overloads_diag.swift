// RUN: %target-swift-frontend -typecheck -verify -enable-experimental-feature Embedded -parse-as-library -wmo -target %target-cpu-apple-macos14 %s

// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// Verify the embedded distributed type-check pass diagnoses missing
// per-type overloads on the user's concrete encoder/decoder/handler types.
// The user's actor system here intentionally OMITS `recordArgument(_: RemoteCallArgument<String>)`,
// `decodeNextArgument(_:String.Type)`, etc. - the diagnostics should fire.

import _Concurrency
import Distributed

public struct EmbeddedActorID: Sendable, Hashable {
  public let id: UInt64
}

public struct MyEncoder: EmbeddedDistributedTargetInvocationEncoder {
  public init() {}
  public mutating func doneRecording() throws {}
  // INTENTIONALLY MISSING: recordArgument(_: RemoteCallArgument<String>)
  // INTENTIONALLY MISSING: recordReturnType(_: String.Type)
}

public struct MyDecoder: EmbeddedDistributedTargetInvocationDecoder {
  public init() {}
  // INTENTIONALLY MISSING: decodeNextArgument(_: String.Type) -> String
}

public struct MyResultHandler: EmbeddedDistributedTargetInvocationResultHandler {
  public init() {}
  public func onReturnVoid() async throws {}
  public func onThrow(error: any Error) async throws {}
  // INTENTIONALLY MISSING: onReturn(_: String) async throws
}

public final class MySystem: EmbeddedDistributedActorSystem, @unchecked Sendable {
  public typealias ActorID = EmbeddedActorID
  public typealias InvocationEncoder = MyEncoder
  public typealias InvocationDecoder = MyDecoder
  public typealias ResultHandler = MyResultHandler

  public init() {}

  public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
      where Act: DistributedActor, Act.ID == ActorID { return nil }
  public func assignID<Act>(_ actorType: Act.Type) -> ActorID
      where Act: DistributedActor, Act.ID == ActorID { return ActorID(id: 0) }
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
  // expected-error@+8{{embedded distributed actor system encoder 'MySystem.InvocationEncoder' (aka 'MyEncoder') is missing an overload of 'recordArgument' for type 'String' in distributed instance method}}
  // expected-note@+7{{add this overload to 'MySystem.InvocationEncoder' (aka 'MyEncoder') (or to an extension of it):  mutating func recordArgument(_ argument: RemoteCallArgument<String>) throws}}
  // expected-error@+6{{embedded distributed actor system decoder 'MySystem.InvocationDecoder' (aka 'MyDecoder') is missing an overload of 'decodeNextArgument' for type 'String' in distributed instance method}}
  // expected-note@+5{{add this overload to 'MySystem.InvocationDecoder' (aka 'MyDecoder') (or to an extension of it):  mutating func decodeNextArgument(_ type: String.Type) throws -> String}}
  // expected-error@+4{{embedded distributed actor system encoder 'MySystem.InvocationEncoder' (aka 'MyEncoder') is missing an overload of 'recordReturnType' for the return type 'String' of distributed instance method}}
  // expected-note@+3{{add this overload to 'MySystem.InvocationEncoder' (aka 'MyEncoder') (or to an extension of it):  mutating func recordReturnType(_ type: String.Type) throws}}
  // expected-error@+2{{embedded distributed actor system result handler 'MySystem.ResultHandler' (aka 'MyResultHandler') is missing an overload of 'onReturn' for the return type 'String' of distributed instance method}}
  // expected-note@+1{{add this overload to 'MySystem.ResultHandler' (aka 'MyResultHandler') (or to an extension of it):  func onReturn(_ value: String) async throws}}
  distributed func hello(name: String) -> String {
    return "Hello, \(name)!"
  }
}
