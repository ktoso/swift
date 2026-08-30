// RUN: %target-swift-frontend -emit-ir -enable-experimental-feature Embedded -parse-as-library -wmo -target %target-cpu-apple-macos14 %s | %FileCheck %s

// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// Multiple distributed actors sharing one actor system compile cleanly
// under Embedded, and each one's distributed thunks are independently
// emitted.

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
  distributed func hello(name: String) -> String { "Hello, \(name)!" }
}

distributed actor Farewell {
  distributed func goodbye(name: String) -> String { "Bye, \(name)!" }
}

@main struct Main {
  static func main() async {
    let system = MySystem()
    let g = Greeter(actorSystem: system)
    let f = Farewell(actorSystem: system)
    _ = try? await g.hello(name: "x")
    _ = try? await f.goodbye(name: "y")
  }
}

// Both actors get their own thunk in IR.
// CHECK-DAG: @"$e{{.+}}GreeterC5hello4nameS2S_tYaKFTE"
// CHECK-DAG: @"$e{{.+}}FarewellC7goodbye4nameS2S_tYaKFTE"

// And the remoteCall<Greeter> / remoteCall<Farewell> specializations.
// CHECK-DAG: $e{{.+}}MySystemC10remoteCall{{.+}}GreeterC_Tg5
// CHECK-DAG: $e{{.+}}MySystemC10remoteCall{{.+}}FarewellC_Tg5
