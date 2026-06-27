// RUN: %target-swift-frontend -emit-ir -enable-experimental-feature Embedded -parse-as-library -wmo -target %target-cpu-apple-macos14 %s | %FileCheck %s

// REQUIRES: swift_in_compiler
// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// Verify a minimal distributed actor using the new
// `EmbeddedDistributedActorSystem` protocol family compiles end-to-end to
// LLVM IR under -enable-experimental-feature Embedded.

import _Concurrency
import Distributed

// ==== ----------------------------------------------------------------------
// MARK: A minimal embedded-friendly actor system

public struct EmbeddedActorID: Sendable, Hashable {
  public let id: UInt64
}

public struct MyEncoder: EmbeddedDistributedTargetInvocationEncoder {
  public init() {}
  public mutating func doneRecording() throws {}
}

extension MyEncoder {
  public mutating func recordArgument(_ value: String, label: String) throws {}
  public mutating func recordReturnType(_ type: String.Type) throws {}
}

public struct MyDecoder: EmbeddedDistributedTargetInvocationDecoder {
  public init() {}
}

extension MyDecoder {
  public mutating func decodeNextArgument(_ type: String.Type) throws -> String {
    return "stub"
  }
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
  public typealias ActorID = EmbeddedActorID
  public typealias InvocationEncoder = MyEncoder
  public typealias InvocationDecoder = MyDecoder
  public typealias ResultHandler = MyResultHandler

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

  public func remoteCall<Act>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder
  ) async throws -> InvocationDecoder
      where Act: DistributedActor, Act.ID == ActorID {
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
}

typealias DefaultDistributedActorSystem = MySystem

// ==== ----------------------------------------------------------------------
// MARK: The actor under test

distributed actor Greeter {
  distributed func hello(name: String) -> String {
    return "Hello, \(name)!"
  }
}

@main struct Main {
  static func main() async {
    let system = MySystem()
    let greeter = Greeter(actorSystem: system)
    do {
      _ = try await greeter.hello(name: "World")
    } catch {
      // ignore
    }
  }
}

// The synthesized distributed thunk for `Greeter.hello` is emitted.
// CHECK: @"$e{{.+}}GreeterC5hello4nameS2S_tYaKFTE"

// The user's specialized `remoteCall<Greeter>` is emitted (no
// generic-over-SerializationRequirement remoteCall is left around).
// CHECK: @"$e{{.+}}MySystemC10remoteCall2on6target10invocation{{.+}}GreeterC_Tg5{{.*}}"

// No accessible-function-table section under Embedded.
// CHECK-NOT: __swift5_acfuncs
