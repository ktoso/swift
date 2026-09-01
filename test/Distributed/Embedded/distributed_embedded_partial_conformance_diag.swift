// RUN: %target-swift-frontend -typecheck -verify -enable-experimental-feature Embedded -parse-as-library -wmo -target %target-cpu-apple-macos14 %s

// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// The serialization-requirement conformance diagnostic is per-type: a
// distributed func whose argument/return types all conform compiles, while one
// that uses a non-conforming type is rejected. Here `String` conforms to the
// system's `MySerializationRequirement` but `Int` does not, so `hello`
// compiles, `square`'s `Int` parameter is diagnosed, and a separate func's
// `Int` result is diagnosed. (The parameter check bails on the first offending
// parameter, so a func with both a bad parameter and a bad result would only
// report the parameter, hence the separate funcs.)

import _Concurrency
import Distributed

public struct MyActorID: Sendable, Hashable {
  public let id: UInt64
}

// `String` conforms; `Int` intentionally does not.
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
  // String conforms, so this func compiles fine.
  distributed func hello(name: String) -> String {
    return "Hello, \(name)!"
  }

  // Int does not conform, so the parameter is rejected. The argument label is
  // `_`, so the parameter renders as '_'. The parameter check bails here, so
  // the result type is not examined by this func.
  // expected-error@+1{{parameter '_' of type 'Int' in distributed instance method does not conform to serialization requirement 'MySerializationRequirement'}}
  distributed func square(_ x: Int) -> Int {
    return x * x
  }

  // The String parameter conforms, so the parameter check passes and the
  // result type is examined: Int does not conform, so the result is rejected.
  // expected-error@+1{{result type 'Int' of distributed instance method 'length' does not conform to serialization requirement 'MySerializationRequirement'}}
  distributed func length(of s: String) -> Int {
    return s.count
  }
}
