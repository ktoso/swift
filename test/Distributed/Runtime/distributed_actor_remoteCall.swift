// XXX: %target-swift-frontend -primary-file %s -emit-sil -parse-as-library -enable-experimental-distributed -disable-availability-checking | %FileCheck %s --enable-var-scope --dump-input=always
// RUN: %target-run-simple-swift( -Xfrontend -module-name=main -Xfrontend -disable-availability-checking -Xfrontend -enable-experimental-distributed -parse-as-library) | %FileCheck %s --dump-input=always

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: distributed

// rdar://76038845
// UNSUPPORTED: use_os_stdlib
// UNSUPPORTED: back_deployment_runtime

// FIXME(distributed): Distributed actors currently have some issues on windows, isRemote always returns false. rdar://82593574
// UNSUPPORTED: windows

import _Distributed

final class Obj: @unchecked Sendable, Codable  {}
struct LargeStruct: Sendable, Codable {
}

distributed actor Greeter {
  distributed func hello() {
    print("EXECUTING HELLO")
  }

  distributed func test(i: Int, s: String) -> String {
    return s
  }

  nonisolated func TESTTESTTESTTEST(i: Int, s: String) async throws -> String {
    // bb0:
    let remote = __isRemoteActor(self)

    if remote {
      // bb1:
      var invocation = try self.actorSystem.makeInvocation()
      try invocation.recordArgument/*<Int>*/(i)
      try invocation.recordArgument/*<String>*/(s)
      try invocation.recordReturnType/*<String>*/(String.self)
      // try invocation.recordErrorType/*<Error>*/(Error.self)
      try invocation.doneRecording()

      let target = RemoteCallTarget(mangledName: "MANGLED_NAME")

      try await self.actorSystem.remoteCall<Self, Never, String>(
          on: self,
          target,
          invocation,
          throwing: Never.self,
          returning: String.self
      )

    } else {
      // bb2:
      await self.test(i: i, s: s)
    }
  }

}


// ==== Fake Transport ---------------------------------------------------------
struct ActorAddress: Sendable, Hashable, Codable {
  let address: String
  init(parse address: String) {
    self.address = address
  }
}

struct FakeActorSystem: DistributedActorSystem {
  typealias ActorID = ActorAddress
  typealias Invocation = FakeInvocation
  typealias SerializationRequirement = Codable

  func resolve<Act>(id: ActorID, as actorType: Act.Type)
  throws -> Act? where Act: DistributedActor {
    return nil
  }

  func assignID<Act>(_ actorType: Act.Type) -> ActorID
          where Act: DistributedActor {
    let id = ActorAddress(parse: "xxx")
    return id
  }

  func actorReady<Act>(_ actor: Act)
      where Act: DistributedActor,
      Act.ID == ActorID {
  }

  func resignID(_ id: ActorID) {
  }

  func makeInvocation() -> Invocation {
    .init()
  }

}

struct FakeInvocation: DistributedTargetInvocation {
  typealias ArgumentDecoder = FakeArgumentDecoder
  typealias SerializationRequirement = Codable

  mutating func recordGenericSubstitution<T>(mangledType: T.Type) throws {}
  mutating func recordArgument<Argument: SerializationRequirement>(argument: Argument) throws {}
  mutating func recordReturnType<R: SerializationRequirement>(mangledType: R.Type) throws {}
  mutating func recordErrorType<E: Error>(mangledType: E.Type) throws {}
  mutating func doneRecording() throws {}

  // === Receiving / decoding -------------------------------------------------

  mutating func decodeGenericSubstitutions() throws -> [Any.Type] { [] }
  func makeArgumentDecoder() -> FakeArgumentDecoder { .init() }
  mutating func decodeReturnType() throws -> Any.Type? { nil }
  mutating func decodeErrorType() throws -> Any.Type? { nil }

  struct FakeArgumentDecoder: DistributedTargetInvocationArgumentDecoder {
    typealias SerializationRequirement = Codable
  }
}

@available(SwiftStdlib 5.5, *)
struct FakeResultHandler: DistributedTargetInvocationResultHandler {
  func onReturn<Res>(value: Res) async throws {
    print("RETURN: \(value)")
  }
  func onThrow<Err: Error>(error: Err) async throws {
    print("ERROR: \(error)")
  }
}

@available(SwiftStdlib 5.5, *)
typealias DefaultDistributedActorSystem = FakeActorSystem

// actual mangled name:
let helloName = "$s4main7GreeterC5helloyyFTE"

func test() async throws {
  let system = FakeActorSystem()

  let local = Greeter(system: system)

  // act as if we decoded an Invocation:
  var invocation = FakeInvocation()

  try await system.executeDistributedTarget(
      on: local,
      mangledTargetName: helloName,
      invocation: &invocation,
      handler: FakeResultHandler()
  )

  // CHECK: done
  print("done")
}

@main struct Main {
  static func main() async {
    try! await test()
  }
}
