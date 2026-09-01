// RUN: %target-swift-frontend -emit-ir -enable-experimental-feature Embedded -enable-experimental-feature EmbeddedDistributed -parse-as-library -wmo -target %target-cpu-apple-macos14 %s | %FileCheck %s

// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// Verify a minimal distributed actor using the new
// `DistributedActorSystem` protocol family compiles end-to-end to
// LLVM IR under -enable-experimental-feature Embedded.

import _Concurrency
import Distributed

// ==== ----------------------------------------------------------------------
// MARK: A minimal embedded-friendly actor system

public struct EmbeddedActorID: Sendable, Hashable {
  public let id: UInt64
}

// The system binds `SerializationRequirement` to its own protocol; `String` is
// the only argument/return type used below, so that is all that must conform.
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
  public typealias ActorID = EmbeddedActorID
  public typealias SerializationRequirement = MySerializationRequirement
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

  public func remoteCall<Act, Res>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder
  ) async throws -> Res
      where Act: DistributedActor, Act.ID == ActorID, Res: MySerializationRequirement {
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

// The user's `remoteCall`, specialized for `<Greeter, String>` (Act = Greeter,
// Res = String), is emitted - no generic-over-SerializationRequirement
// remoteCall is left around. The `GreeterC_SS` in the mangling is the
// `<Greeter, String>` specialization.
// CHECK: @"$e{{.+}}MySystemC10remoteCall2on6target10invocation{{.+}}GreeterC_SSTg5{{.*}}"

// Remote-proxy allocation goes through the embedded-only entry point with a
// compiler-computed allocSize and alignMask (the minimal embedded
// ClassMetadata has no InstanceSize/InstanceAlignMask the runtime could read).
// CHECK-NOT: call swiftcc {{.*}}@swift_distributedActor_remote_initialize(
// CHECK: call swiftcc ptr @swift_distributedActor_remote_initialize_embedded(ptr {{.*}}, i64 {{[0-9]+}}, i64 {{[0-9]+}})

// No accessible-function-table section under Embedded.
// CHECK-NOT: __swift5_acfuncs
