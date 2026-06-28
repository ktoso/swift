// RUN: %target-swift-frontend -typecheck -verify -enable-experimental-feature Embedded -parse-as-library -wmo -target %target-cpu-apple-macos14 %s

// REQUIRES: swift_in_compiler
// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// Phase 2 placeholder: `any P` / `some P` parameter or return types in
// `distributed func` signatures are diagnosed under Embedded with a
// clear "not yet supported" message. Full `@Resolvable` `$P`-stub-based
// substitution is the planned Phase 2 implementation.

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
  public mutating func decodeNextArgument(_: String.Type) throws -> String { "" }
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
    on actor: Act, target: RemoteCallTarget, invocation: inout InvocationEncoder
  ) async throws -> InvocationDecoder
      where Act: DistributedActor, Act.ID == ActorID { fatalError() }

  public func remoteCallVoid<Act>(
    on actor: Act, target: RemoteCallTarget, invocation: inout InvocationEncoder
  ) async throws
      where Act: DistributedActor, Act.ID == ActorID { fatalError() }
}

typealias DefaultDistributedActorSystem = MySystem

// A protocol refining DistributedActor that a Phase 2 implementation
// would use with @Resolvable.
public protocol Worker: DistributedActor where ActorSystem == MySystem {
  distributed func work(name: String) -> String
}

distributed actor Hub {
  // expected-error@+2{{parameter 'to' of 'any' type 'any Worker' in distributed instance method is not yet supported in Embedded Swift}}
  // expected-note@+1{{Embedded Swift does not yet emit the wire-level proxy ($P stub) for '@Resolvable' protocols. Use a concrete type that conforms to a compile-time-known serialization protocol instead.}}
  distributed func sendAny(to worker: any Worker) -> String {
    return "sent"
  }

  // `some P` parameter (rewritten internally as an opaque archetype).
  // expected-error@+2{{parameter 'to' of 'some' type 'some Worker' in distributed instance method is not yet supported in Embedded Swift}}
  // expected-note@+1{{Embedded Swift does not yet emit the wire-level proxy ($P stub) for '@Resolvable' protocols. Use a concrete type that conforms to a compile-time-known serialization protocol instead.}}
  distributed func sendSome(to worker: some Worker) -> String {
    return "sent"
  }

  // `any P` result type.
  // expected-error@+2{{'any' return type 'any Worker' of distributed instance method is not yet supported in Embedded Swift}}
  // expected-note@+1{{Embedded Swift does not yet emit the wire-level proxy ($P stub) for '@Resolvable' protocols. Use a concrete type that conforms to a compile-time-known serialization protocol instead.}}
  distributed func pickWorker() -> any Worker {
    fatalError()
  }

  // A regular concrete-typed distributed func still compiles fine,
  // even alongside the rejected ones above.
  distributed func hello(name: String) -> String {
    return "Hello, \(name)!"
  }
}
