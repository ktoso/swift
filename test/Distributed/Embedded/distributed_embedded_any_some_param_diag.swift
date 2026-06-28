// RUN: %target-swift-frontend -typecheck -verify -enable-experimental-feature Embedded -parse-as-library -wmo -target %target-cpu-apple-macos14 -plugin-path %swift-plugin-dir %s

// REQUIRES: swift_in_compiler
// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// Phase 2 embedded `@Resolvable` support: `any P` parameters and returns
// where `P` is annotated with `@Resolvable` get the wire-level `$P` stub
// substitution at the synthesized distributed thunk's call site and the
// per-type encoder/decoder overload check accepts `$P`. `some P` and
// generic distributed funcs remain rejected; `any P` without `@Resolvable`
// remains rejected (no `$P` stub exists for non-resolvable protocols).

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

// A `@Resolvable` protocol: the macro emits a `$Worker` stub. `any Worker`
// parameters/returns are accepted; the synthesized distributed thunk
// substitutes `$Worker` at the wire-level call site.
@Resolvable
public protocol RWorker: DistributedActor where ActorSystem == MySystem {
  distributed func work(name: String) -> String
}

// `$RWorker` overloads on the user's invocation pieces, needed for the
// per-type coverage check to pass for `any RWorker`.
extension MyEncoder {
  public mutating func recordArgument(_ argument: RemoteCallArgument<$RWorker>) throws {}
  public mutating func recordReturnType(_ type: $RWorker.Type) throws {}
}
extension MyDecoder {
  public mutating func decodeNextArgument(_: $RWorker.Type) throws -> $RWorker {
    fatalError()
  }
}
extension MyResultHandler {
  public func onReturn(_ value: $RWorker) async throws {}
}

distributed actor Hub {
  // `any P` where P is not `@Resolvable`: rejected, no `$P` stub exists
  // expected-error@+2{{parameter 'to' of 'any' type 'any Worker' in distributed instance method is not yet supported in Embedded Swift}}
  // expected-note@+1{{Embedded Swift does not yet emit the wire-level proxy ($P stub) for '@Resolvable' protocols. Use a concrete type that conforms to a compile-time-known serialization protocol instead.}}
  distributed func sendAny(to worker: any Worker) -> String {
    return "sent"
  }

  // `some P` parameter: rejected even if P has `@Resolvable`, generic
  // specialization isn't supported under embedded
  // expected-error@+1{{parameter 'to' of 'some' type 'some RWorker' in distributed instance method is not supported in Embedded Swift; use 'any RWorker' instead}}
  distributed func sendSome(to worker: some RWorker) -> String {
    return "sent"
  }

  // `any P` result type without `@Resolvable`: rejected
  // expected-error@+2{{'any' return type 'any Worker' of distributed instance method is not yet supported in Embedded Swift}}
  // expected-note@+1{{Embedded Swift does not yet emit the wire-level proxy ($P stub) for '@Resolvable' protocols. Use a concrete type that conforms to a compile-time-known serialization protocol instead.}}
  distributed func pickWorker() -> any Worker {
    fatalError()
  }

  // `any P` where P is `@Resolvable`: accepted, thunk substitutes `$P`
  distributed func sendResolvableAny(to worker: any RWorker) -> String {
    return "sent"
  }

  // `any P` return where P is `@Resolvable`: accepted
  distributed func pickResolvable() -> any RWorker {
    fatalError()
  }

  // User-written generic distributed func: rejected up front
  // expected-error@+1{{generic 'distributed func' is not supported in Embedded Swift; use concrete parameter and return types in distributed instance method}}
  distributed func sendGeneric<T: Sendable>(_ value: T) -> String {
    return "sent"
  }

  // A regular concrete-typed distributed func still compiles fine,
  // even alongside the rejected ones above.
  distributed func hello(name: String) -> String {
    return "Hello, \(name)!"
  }
}
