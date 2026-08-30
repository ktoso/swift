// RUN: %target-swift-frontend -emit-ir -enable-experimental-feature Embedded -parse-as-library -wmo -target %target-cpu-apple-macos14 %s | %FileCheck %s

// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// Verify that under Embedded mode, distributed-actor code does NOT pull in
// the standard runtime entry points that rely on demangling, metadata
// reconstruction, or the global accessible-function table. None of these
// exist in the Embedded runtime; their presence in emitted IR would mean
// link errors at best, and broken codegen at worst.

import _Concurrency
import Distributed

public struct EmbeddedActorID: Sendable, Hashable {
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
      where Act: DistributedActor, Act.ID == ActorID { return nil }
  public func assignID<Act>(_ actorType: Act.Type) -> ActorID
      where Act: DistributedActor, Act.ID == ActorID { return ActorID(id: 0) }
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
  distributed func hello(name: String) -> String { "hi \(name)" }
}

@main struct Main {
  static func main() async {
    let system = MySystem()
    let greeter = Greeter(actorSystem: system)
    _ = try? await greeter.hello(name: "World")
  }
}

// Sanity: the test actually produced output.
// CHECK: ModuleID

// === Runtime symbols that must NOT appear in Embedded distributed IR ===

// Accessible-function table lookup. Replaced by per-actor accessor
// table (see Phase 1 plan).
// CHECK-NOT: swift_findAccessibleFunction

// Runtime mangled-name -> Metadata reconstruction. Embedded has no
// demangler.
// CHECK-NOT: swift_getTypeByMangledNode
// CHECK-NOT: swift_getTypeByMangledName
// CHECK-NOT: swift_func_getParameterCount
// CHECK-NOT: swift_func_getParameterTypeInfo
// CHECK-NOT: swift_func_getReturnTypeInfo

// Runtime protocol-conformance lookup. Not used by distributed dispatch
// under Embedded; all conformances are statically known.
// CHECK-NOT: call {{.*}} @swift_conformsToProtocol(
// CHECK-NOT: call {{.*}} @swift_conformsToProtocol2(

// Distributed-specific witness-table malloc (used for runtime ad-hoc
// witness retrieval) - unused under Embedded.
// CHECK-NOT: swift_distributed_getWitnessTables

// The standard receiver entry point - replaced under Embedded by a
// thinner per-actor dispatch.
// CHECK-NOT: swift_distributed_execute_target
