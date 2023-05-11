// RUN: %empty-directory(%t)
// RUN: %target-build-swift -emit-irgen -module-name main -Xfrontend -disable-availability-checking -j2 -parse-as-library -I %t %s
// RUN: %target-build-swift -module-name main -Xfrontend -disable-availability-checking -j2 -parse-as-library -I %t %s -o %t/a.out
// RUN: %target-codesign %t/a.out
// RUN: %target-run %t/a.out | %FileCheck %s --color --dump-input=always

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: distributed

// rdar://76038845
// UNSUPPORTED: use_os_stdlib
// UNSUPPORTED: back_deployment_runtime

// FIXME(distributed): Distributed actors currently have some issues on windows, isRemote always returns false. rdar://82593574
// UNSUPPORTED: OS=windows-msvc

import Darwin
import Distributed

typealias DefaultDistributedActorSystem = FakeDecodeSystem

final class SomeClass: Sendable, Codable {
  let file: String
  let line: Int

  init(file: String = #fileID, line: Int = #line) {
    self.file = file
    self.line = line
    fputs("SomeClass init: \(Unmanaged.passUnretained(self).toOpaque()) @ (\(file):\(line)\n", stderr)
    print("SomeClass init: \(Unmanaged.passUnretained(self).toOpaque()) @ (\(file):\(line)\n")
  }
  deinit {
    fputs("SomeClass deinit: \(Unmanaged.passUnretained(self).toOpaque()) @ (\(file):\(line)\n", stderr)
    print("SomeClass deinit: \(Unmanaged.passUnretained(self).toOpaque()) @ (\(file):\(line)\n")
  }
}

distributed actor Greeter {
  distributed func take(_ clazz: SomeClass) {
    fputs("take: SomeClass param: \(clazz) (object: \(Unmanaged.passUnretained(clazz).toOpaque()))\n", stderr)
  }
}

func test() async throws {
  let system = DefaultDistributedActorSystem()

  let local = Greeter(actorSystem: system)
  let ref = try Greeter.resolve(id: local.id, using: system)

  try await ref.take(SomeClass())

  // CHECK: > made up SomeClass instance: 0x[[ADDRESS:.*]]
  // CHECK: SomeClass deinit 0x[[ADDRESS]]
}

@main struct Main {
  static func main() async {
    try! await test()
  }
}

// ==================


@available(SwiftStdlib 5.7, *)
public final class FakeDecodeSystem: DistributedActorSystem, @unchecked Sendable {
  public typealias ActorID = ActorAddress
  public typealias InvocationEncoder = FakeInvocationEncoder
  public typealias InvocationDecoder = FakeInvocationDecoder
  public typealias SerializationRequirement = Codable
  public typealias ResultHandler = FakeRoundtripResultHandler

  var activeActors: [ActorID: any DistributedActor] = [:]

  public init() {}

  public func resolve<Act>(id: ActorID, as actorType: Act.Type)
      throws -> Act? where Act: DistributedActor {
    print("| resolve \(id) as remote // this system always resolves as remote")
    return nil
  }

  public func assignID<Act>(_ actorType: Act.Type) -> ActorID
      where Act: DistributedActor {
    let id = ActorAddress(parse: "<unique-id>")
    print("| assign id: \(id) for \(actorType)")
    return id
  }

  public func actorReady<Act>(_ actor: Act)
      where Act: DistributedActor,
      Act.ID == ActorID {
    print("| actor ready: \(actor)")
    self.activeActors[actor.id] = actor
  }

  public func resignID(_ id: ActorID) {
    print("X resign id: \(id)")
  }

  public func makeInvocationEncoder() -> InvocationEncoder {
    .init()
  }

  private var remoteCallResult: Any? = nil
  private var remoteCallError: Error? = nil

  public func remoteCall<Act, Err, Res>(
      on actor: Act,
      target: RemoteCallTarget,
      invocation: inout InvocationEncoder,
      throwing errorType: Err.Type,
      returning returnType: Res.Type
  ) async throws -> Res
      where Act: DistributedActor,
      Act.ID == ActorID,
      Err: Error,
      Res: SerializationRequirement {
    print("  >> remoteCall: on:\(actor), target:\(target), invocation:\(invocation), throwing:\(String(reflecting: errorType)), returning:\(String(reflecting: returnType))")
    guard let targetActor = activeActors[actor.id] else {
      fatalError("Attempted to call mock 'roundtrip' on: \(actor.id) without active actor")
    }

    func doIt<A: DistributedActor>(active: A) async throws -> Res {
      guard (actor.id) == active.id as! ActorID else {
        fatalError("Attempted to call mock 'roundtrip' on unknown actor: \(actor.id), known: \(active.id)")
      }

      let resultHandler = FakeRoundtripResultHandler { value in
        self.remoteCallResult = value
        self.remoteCallError = nil
      } onError: { error in
        self.remoteCallResult = nil
        self.remoteCallError = error
      }

      var decoder = invocation.makeDecoder()

      try await executeDistributedTarget(
          on: active,
          target: target,
          invocationDecoder: &decoder,
          handler: resultHandler
      )

      switch (remoteCallResult, remoteCallError) {
      case (.some(let value), nil):
        print("  << remoteCall return: \(value)")
        return remoteCallResult! as! Res
      case (nil, .some(let error)):
        print("  << remoteCall throw: \(error)")
        throw error
      default:
        fatalError("No reply!")
      }
    }
    return try await _openExistential(targetActor, do: doIt)
  }

  public func remoteCallVoid<Act, Err>(
      on actor: Act,
      target: RemoteCallTarget,
      invocation: inout InvocationEncoder,
      throwing errorType: Err.Type
  ) async throws
      where Act: DistributedActor,
      Act.ID == ActorID,
      Err: Error {
    print("  >> remoteCallVoid: on:\(actor), target:\(target), invocation:\(invocation), throwing:\(String(reflecting: errorType))")
    guard let targetActor = activeActors[actor.id] else {
      fatalError("Attempted to call mock 'roundtrip' on: \(actor.id) without active actor")
    }

    func doIt<A: DistributedActor>(active: A) async throws {
      guard (actor.id) == active.id as! ActorID else {
        fatalError("Attempted to call mock 'roundtrip' on unknown actor: \(actor.id), known: \(active.id)")
      }

      let resultHandler = FakeRoundtripResultHandler { value in
        self.remoteCallResult = value
        self.remoteCallError = nil
      } onError: { error in
        self.remoteCallResult = nil
        self.remoteCallError = error
      }

      var decoder = invocation.makeDecoder()

      try await executeDistributedTarget(
          on: active,
          target: target,
          invocationDecoder: &decoder,
          handler: resultHandler
      )

      switch (remoteCallResult, remoteCallError) {
      case (.some, nil):
        return
      case (nil, .some(let error)):
        print("  << remoteCall throw: \(error)")
        throw error
      default:
        fatalError("No reply!")
      }
    }
    try await _openExistential(targetActor, do: doIt)
  }

}

@available(SwiftStdlib 5.7, *)
public struct FakeInvocationEncoder : DistributedTargetInvocationEncoder {
  public typealias SerializationRequirement = Codable

  var genericSubs: [Any.Type] = []
  var arguments: [Any] = []
  var returnType: Any.Type? = nil
  var errorType: Any.Type? = nil

  public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {
    print(" > encode generic sub: \(String(reflecting: type))")
    genericSubs.append(type)
  }

  public mutating func recordArgument<Value: SerializationRequirement>(
      _ argument: RemoteCallArgument<Value>) throws {
    print(" > encode argument name:\(argument.label ?? "_"), value: \(argument.value)")
    arguments.append(argument.value)
  }

  public mutating func recordErrorType<E: Error>(_ type: E.Type) throws {
    print(" > encode error type: \(String(reflecting: type))")
    self.errorType = type
  }

  public mutating func recordReturnType<R: SerializationRequirement>(_ type: R.Type) throws {
    print(" > encode return type: \(String(reflecting: type))")
    self.returnType = type
  }

  public mutating func doneRecording() throws {
    print(" > done recording")
  }

  public func makeDecoder() -> FakeInvocationDecoder {
    return .init(
        args: arguments,
        substitutions: genericSubs,
        returnType: returnType,
        errorType: errorType
    )
  }
}

// === decoding --------------------------------------------------------------

// !!! WARNING !!!
// This is a 'final class' on purpose, to see that we retain the ad-hoc witness
// for 'decodeNextArgument'; Do not change it to just a class!
@available(SwiftStdlib 5.7, *)
public final class FakeInvocationDecoder: DistributedTargetInvocationDecoder {
  public typealias SerializationRequirement = Codable

  var genericSubs: [Any.Type] = []
  var returnType: Any.Type? = nil
  var errorType: Any.Type? = nil

  fileprivate init(
      args: [Any],
      substitutions: [Any.Type] = [],
      returnType: Any.Type? = nil,
      errorType: Any.Type? = nil
  ) {
    self.genericSubs = substitutions
    self.returnType = returnType
    self.errorType = errorType
    fputs("FakeInvocationDecoder init: \(Unmanaged.passUnretained(self).toOpaque())\n", stderr)
  }

  deinit {
    fputs("FakeInvocationDecoder deinit: \(Unmanaged.passUnretained(self).toOpaque())\n", stderr)
  }

  public func decodeGenericSubstitutions() throws -> [Any.Type] {
    print("  > decode generic subs: \(genericSubs)")
    return genericSubs
  }

  public func decodeNextArgument<Argument: SerializationRequirement>() throws -> Argument {
    let argument = SomeClass()
    fputs("  > made up SomeClass instance: \(Unmanaged.passUnretained(argument).toOpaque())\n", stderr)
    print("  > made up SomeClass instance: \(Unmanaged.passUnretained(argument).toOpaque())\n")
    print("  > fake decode argument: \(argument) (\(Unmanaged.passUnretained(argument).toOpaque()))")
    return argument as! Argument
  }

  public func decodeErrorType() throws -> Any.Type? {
    print("  > decode return type: \(errorType.map { String(reflecting: $0) }  ?? "nil")")
    return self.errorType
  }

  public func decodeReturnType() throws -> Any.Type? {
    print("  > decode return type: \(returnType.map { String(reflecting: $0) }  ?? "nil")")
    return self.returnType
  }
}

@available(SwiftStdlib 5.7, *)
public struct FakeRoundtripResultHandler: DistributedTargetInvocationResultHandler {
  public typealias SerializationRequirement = Codable

  let storeReturn: (any Any) -> Void
  let storeError: (any Error) -> Void
  init(_ storeReturn: @escaping (Any) -> Void, onError storeError: @escaping (Error) -> Void) {
    self.storeReturn = storeReturn
    self.storeError = storeError
  }

  public func onReturn<Success: SerializationRequirement>(value: Success) async throws {
    print(" << onReturn: \(value)")
    storeReturn(value)
  }

  public func onReturnVoid() async throws {
    print(" << onReturnVoid: ()")
    storeReturn(())
  }

  public func onThrow<Err: Error>(error: Err) async throws {
    print(" << onThrow: \(error)")
    storeError(error)
  }
}

public struct ActorAddress: Hashable, Sendable, Codable {
  public let address: String

  public init(parse address: String) {
    self.address = address
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.address = try container.decode(String.self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(self.address)
  }
}
