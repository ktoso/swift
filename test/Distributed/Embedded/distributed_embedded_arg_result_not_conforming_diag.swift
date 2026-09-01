// RUN: %target-swift-frontend -typecheck -verify -enable-experimental-feature Embedded -parse-as-library -wmo -target %target-cpu-apple-macos14 %s

// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// Verify the embedded distributed type-check pass diagnoses argument and
// return types that do not conform to the system's `SerializationRequirement`.
// The system binds `SerializationRequirement` to `MySerializationRequirement`
// but `String` is intentionally NOT conformed to it, so a `String` parameter
// and a `String` return type are both rejected - the same conformance
// diagnostics normal (non-embedded) Swift uses, now that the embedded shape
// carries a real `SerializationRequirement` instead of ad-hoc per-type
// overloads. (The parameter check bails on the first offending parameter, so
// the parameter and result diagnostics are exercised by separate funcs.)

import _Concurrency
import Distributed

public struct EmbeddedActorID: Sendable, Hashable {
  public let id: UInt64
}

// The system's serialization requirement. `String` is intentionally NOT
// conformed to it below.
public protocol MySerializationRequirement {}

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
    fatalError("stub")
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
  public typealias ActorID = EmbeddedActorID
  public typealias SerializationRequirement = MySerializationRequirement
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

  public func remoteCall<Act, Res>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder
  ) async throws -> Res
      where Act: DistributedActor, Act.ID == ActorID, Res: MySerializationRequirement { fatalError() }

  public func remoteCallVoid<Act>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder
  ) async throws
      where Act: DistributedActor, Act.ID == ActorID { fatalError() }
}

typealias DefaultDistributedActorSystem = MySystem

distributed actor Greeter {
  // `String` does not conform, so the parameter is rejected. The parameter
  // check bails on the first non-conforming parameter, so this func exercises
  // only the parameter diagnostic.
  // expected-error@+1{{parameter 'name' of type 'String' in distributed instance method does not conform to serialization requirement 'MySerializationRequirement'}}
  distributed func hello(name: String) {
  }

  // A func with no parameters, so the parameter check passes and the result
  // type is examined: `String` does not conform, so the result is rejected.
  // expected-error@+1{{result type 'String' of distributed instance method 'greeting' does not conform to serialization requirement 'MySerializationRequirement'}}
  distributed func greeting() -> String {
    return "Hello!"
  }
}
