// RUN: %target-swift-frontend -typecheck -verify -enable-experimental-feature Embedded -parse-as-library -wmo -target %target-cpu-apple-macos14 %s

// REQUIRES: swift_in_compiler
// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// The overload-coverage diagnostic isn't String-specific: it fires for
// any type used in a distributed func signature that doesn't have a
// matching per-type overload on the encoder/decoder/handler.

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
  // String overloads only - intentionally NO Int overloads
  public mutating func recordArgument(_ value: String, label: String) throws {}
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
  // String-only func compiles fine.
  distributed func hello(name: String) -> String {
    return "Hello, \(name)!"
  }

  // Int-using func triggers the missing-overload diagnostic on
  // encoder.recordArgument(_:Int,label:), decoder.decodeNextArgument(_:Int.Type),
  // encoder.recordReturnType(_:Int.Type), and handler.onReturn(_:Int).
  // The parameter label is `_` (since `square(_ x: Int)`).
  // expected-error@+8{{embedded distributed actor system encoder 'MySystem.InvocationEncoder' (aka 'MyEncoder') is missing an overload of 'recordArgument' for parameter '_' of type 'Int' in distributed instance method}}
  // expected-note@+7{{add this overload to 'MySystem.InvocationEncoder' (aka 'MyEncoder') (or to an extension of it):  func recordArgument(_ value: Int, label: String) throws}}
  // expected-error@+6{{embedded distributed actor system decoder 'MySystem.InvocationDecoder' (aka 'MyDecoder') is missing an overload of 'decodeNextArgument' for parameter '_' of type 'Int' in distributed instance method}}
  // expected-note@+5{{add this overload to 'MySystem.InvocationDecoder' (aka 'MyDecoder') (or to an extension of it):  func decodeNextArgument(_ type: Int.Type) throws -> Int}}
  // expected-error@+4{{embedded distributed actor system encoder 'MySystem.InvocationEncoder' (aka 'MyEncoder') is missing an overload of 'recordReturnType' for the return type 'Int' of distributed instance method}}
  // expected-note@+3{{add this overload to 'MySystem.InvocationEncoder' (aka 'MyEncoder') (or to an extension of it):  func recordReturnType(_ type: Int.Type) throws}}
  // expected-error@+2{{embedded distributed actor system result handler 'MySystem.ResultHandler' (aka 'MyResultHandler') is missing an overload of 'onReturn' for the return type 'Int' of distributed instance method}}
  // expected-note@+1{{add this overload to 'MySystem.ResultHandler' (aka 'MyResultHandler') (or to an extension of it):  func onReturn(_ value: Int) async throws}}
  distributed func square(_ x: Int) -> Int {
    return x * x
  }
}
