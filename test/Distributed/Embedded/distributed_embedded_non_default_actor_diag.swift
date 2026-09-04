// RUN: %target-swift-frontend -typecheck -verify -enable-experimental-feature Embedded -enable-experimental-feature EmbeddedDistributed -parse-as-library -wmo -target %target-cpu-apple-macos14 %s

// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// A distributed actor with a custom executor is a non-default actor. The
// embedded runtime omits the NonDefaultDistributedActor machinery, so such an
// actor traps at runtime in swift_distributedActor_remote_initialize. Diagnose
// the declaration up front rather than allowing that silent runtime trap.

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

// A minimal custom serial executor. Providing 'unownedExecutor' on the actor
// below makes it a non-default actor.
final class MyExecutor: SerialExecutor {
  func enqueue(_ job: consuming ExecutorJob) {}
}

// A default-actor distributed actor is accepted: no custom executor, so the
// synthesized 'unownedExecutor' carries the default-actor semantics.
distributed actor DefaultGreeter {
  distributed func hello(name: String) -> String {
    return "Hello, \(name)!"
  }
}

// A distributed actor that supplies its own executor is a non-default actor
// and is rejected under Embedded Swift.
// expected-error@+1{{distributed actor 'CustomGreeter' with a custom executor is not supported in Embedded Swift; remove the 'unownedExecutor' property to use the default actor executor}}
distributed actor CustomGreeter {
  nonisolated var unownedExecutor: UnownedSerialExecutor {
    MyExecutor().asUnownedSerialExecutor()
  }

  distributed func hello(name: String) -> String {
    return "Hello, \(name)!"
  }
}
