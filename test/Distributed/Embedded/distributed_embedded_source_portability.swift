// RUN: %target-swift-frontend -typecheck -enable-experimental-feature Embedded -parse-as-library -wmo -target %target-cpu-apple-macos14 %s
// RUN: %target-swift-frontend -typecheck -target %target-cpu-apple-macos14 %s

// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// Source-portability acceptance test for the collapsed
// `DistributedActorSystem` protocol family. The SAME `distributed actor`
// and `distributed func`, and the SAME actor-system conformance clause
// and identity/lifecycle methods, typecheck BOTH with
// `-enable-experimental-feature Embedded` and without it.
//
// The only per-mode layer is the `remoteCall` family signature and the
// `SerializationRequirement` binding. The encoder / decoder / handler now use
// the SAME generic-over-`SerializationRequirement` methods in both modes; what
// stays mode-specific is: (a) the `remoteCall` family - under Embedded it drops
// the `<Err>` generic parameter and the `throwing:` / `returning:` metatype
// parameters, (b) the requirement itself - Embedded has no `Codable`, so it
// binds `SerializationRequirement` to a plain marker protocol instead, and
// (c) the extra encoder / decoder members (`recordGenericSubstitution`,
// `recordReturnType`, `decodeReturnType`, ...) that only non-embedded needs.
// That split is expected - it is the serialization layer, which stays
// mode-specific by design.

import _Concurrency
import Distributed

// ==== ----------------------------------------------------------------------
// MARK: Portable declarations (identical in both modes)

public struct MyActorID: Sendable, Hashable {
  public let id: UInt64
}

// The actor `ID` type satisfies the serialization requirement only in
// non-embedded mode - under Embedded a distributed actor gets no `Codable`
// conformance, so its `ID` needs none either. This is the same
// mode-specific serialization layer that the encoder/decoder/handler live in
#if !$Embedded
extension MyActorID: Codable {}
#else
// Embedded has no `Codable`, so the system binds `SerializationRequirement` to
// this plain marker protocol instead. Only the argument / return types the
// distributed funcs actually move need to conform - the actor `ID` does not,
// since actor references are not serialized here
public protocol MySerializationRequirement {}
extension String: MySerializationRequirement {}
#endif

public final class MySystem: DistributedActorSystem, @unchecked Sendable {
  public typealias ActorID = MyActorID
  public typealias InvocationEncoder = MyEncoder
  public typealias InvocationDecoder = MyDecoder
  public typealias ResultHandler = MyResultHandler
#if $Embedded
  public typealias SerializationRequirement = MySerializationRequirement
#else
  public typealias SerializationRequirement = Codable
#endif

  public init() {}

  public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
      where Act: DistributedActor, Act.ID == ActorID {
    return nil
  }
  public func assignID<Act>(_ actorType: Act.Type) -> ActorID
      where Act: DistributedActor, Act.ID == ActorID {
    return ActorID(id: 0)
  }
  public func actorReady<Act>(_ actor: Act)
      where Act: DistributedActor, Act.ID == ActorID {}
  public func resignID(_ id: ActorID) {}

  public func makeInvocationEncoder() -> InvocationEncoder { .init() }

  // ==== --------------------------------------------------------------------
  // MARK: Mode-specific remoteCall family

#if $Embedded
  public func remoteCall<Act, Res>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder
  ) async throws -> Res
      where Act: DistributedActor, Act.ID == ActorID,
            Res: SerializationRequirement {
    fatalError("not implemented")
  }
  public func remoteCallVoid<Act>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder
  ) async throws
      where Act: DistributedActor, Act.ID == ActorID {
    fatalError("not implemented")
  }
#else
  public func remoteCall<Act, Err, Res>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder,
    throwing: Err.Type,
    returning: Res.Type
  ) async throws -> Res
      where Act: DistributedActor, Act.ID == ActorID,
            Err: Error, Res: SerializationRequirement {
    fatalError("not implemented")
  }
  public func remoteCallVoid<Act, Err>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder,
    throwing: Err.Type
  ) async throws
      where Act: DistributedActor, Act.ID == ActorID, Err: Error {
    fatalError("not implemented")
  }
#endif
}

public typealias DefaultDistributedActorSystem = MySystem

distributed actor Greeter {
  distributed func hello(name: String) -> String {
    return "Hello, \(name)!"
  }
}

// ==== ----------------------------------------------------------------------
// MARK: Mode-specific serialization layer

#if $Embedded

public struct MyEncoder: DistributedTargetInvocationEncoder {
  public init() {}
  public mutating func doneRecording() throws {}
  public mutating func recordArgument<Value: MySerializationRequirement>(
      _ argument: RemoteCallArgument<Value>) throws {}
}

public struct MyDecoder: DistributedTargetInvocationDecoder {
  public init() {}
  public mutating func decodeNextArgument<Argument: MySerializationRequirement>() throws -> Argument {
    fatalError("stub")
  }
}

public struct MyResultHandler: DistributedTargetInvocationResultHandler {
  public init() {}
  public func onReturnVoid() async throws {}
  public func onThrow(error: any Error) async throws {}
  public func onReturn<Success: MySerializationRequirement>(_ value: Success) async throws {}
}

#else

public struct MyEncoder: DistributedTargetInvocationEncoder {
  public typealias SerializationRequirement = Codable
  public init() {}
  public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {}
  public mutating func recordArgument<Value: SerializationRequirement>(_ argument: RemoteCallArgument<Value>) throws {}
  public mutating func recordReturnType<R: SerializationRequirement>(_ type: R.Type) throws {}
  public mutating func recordErrorType<E: Error>(_ type: E.Type) throws {}
  public mutating func doneRecording() throws {}
}

public final class MyDecoder: DistributedTargetInvocationDecoder {
  public typealias SerializationRequirement = Codable
  public init() {}
  public func decodeGenericSubstitutions() throws -> [Any.Type] { [] }
  public func decodeNextArgument<Argument: SerializationRequirement>() throws -> Argument { fatalError() }
  public func decodeReturnType() throws -> Any.Type? { nil }
  public func decodeErrorType() throws -> Any.Type? { nil }
}

public struct MyResultHandler: DistributedTargetInvocationResultHandler {
  public typealias SerializationRequirement = Codable
  public init() {}
  public func onReturn<Success: SerializationRequirement>(value: Success) async throws {}
  public func onReturnVoid() async throws {}
  public func onThrow<Err: Error>(error: Err) async throws {}
}

#endif
