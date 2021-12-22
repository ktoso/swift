// XXX: %target-swift-frontend -module-name=main -primary-file %s -emit-sil -parse-as-library -enable-experimental-distributed -disable-availability-checking | %FileCheck %s --enable-var-scope --dump-input=always
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

struct Location : Sendable, Hashable, Codable {
  let address: String
}

class ResultHandler : DistributedTargetInvocationResultHandler {
  var result: Result<Any, Error>? = nil

  func onReturn<Res>(value: Res) async throws {
    result = .success(value)
  }

  func onThrow<Err: Error>(error: Err) async throws {
    result = .failure(error)
  }
}

final class InProcessSystem : DistributedActorSystem, @unchecked Sendable {
  typealias ActorID = Location
  typealias Invocation = FakeInvocation
  typealias SerializationRequirement = Codable

  var nextID = 0
  var managed: [Location: DistributedActor] = [:]

  func resolve<Act>(id: ActorID, as actorType: Act.Type)
      throws -> Act? where Act: DistributedActor {
    return nil
  }

  func assignID<Act>(_ actorType: Act.Type) -> ActorID
      where Act: DistributedActor {
    let id = Location(address: "localhost#\(self.nextID)")
    self.nextID += 1
    print("\(self) - assignID(\(actorType)): \(id)")
    return id
  }

  func actorReady<Act>(_ actor: Act)
      where Act: DistributedActor,
      Act.ID == ActorID {
  }

  func resignID(_ id: ActorID) {
  }

  func makeInvocation() -> Invocation {
    return .init()
  }

  func remoteCall<Act, Err, Res>(
      on actor: Act,
      target: RemoteCallTarget,
      invocation: Invocation,
      throwing: Err.Type,
      returning: Res.Type
  ) async throws -> Res
      where Act: DistributedActor,
            Act.ID == ActorID,
            Res: SerializationRequirement {
    let handler = ResultHandler()

    let invocation = makeInvocation()

    try await executeDistributedTarget(
        on: actor,
        mangledTargetName: target.mangledName,
        invocation: invocation,
        handler: handler)

    switch (handler.result!) {
    case .success(let result):
      return result as! Res
    case .failure(let error):
      throw error
    }
  }
}

struct FakeInvocation : DistributedTargetInvocation {
  typealias ArgumentDecoder = FakeArgumentDecoder
  typealias SerializationRequirement = Codable

  mutating func recordGenericSubstitution<T>(mangledType: T.Type) throws {}
  mutating func recordArgument<Argument: SerializationRequirement>(argument: Argument) throws {}
  mutating func recordReturnType<R: SerializationRequirement>(mangledType: R.Type) throws {}
  mutating func recordErrorType<E: Error>(mangledType: E.Type) throws {}
  mutating func doneRecording() throws {}

  // === Receiving / decoding -------------------------------------------------
  mutating func decodeGenericSubstitutions() throws -> [Any.Type] { [] }
  mutating func argumentDecoder() -> FakeArgumentDecoder { .init() }
  mutating func decodeReturnType() throws -> Any.Type? { nil }
  mutating func decodeErrorType() throws -> Any.Type? { nil }

  struct FakeArgumentDecoder: DistributedTargetInvocationArgumentDecoder {
    typealias SerializationRequirement = Codable
  }
}

struct Token : Sendable, Hashable, Codable {
  let data: Int64

  init(_ token: Int64) {
    self.data = token
  }

  static func from(string: String) -> Token {
    var hasher = Hasher()
    string.hash(into: &hasher)

    return Token(Int64(hasher.finalize()))
  }
}

func <(lhs: Token, rhs: Token) -> Bool {
  return lhs.data < rhs.data
}

func >=(lhs: Token, rhs: Token) -> Bool {
  return lhs.data >= rhs.data
}

distributed actor TokenRange: CustomStringConvertible {
  typealias ActorSystem = InProcessSystem

  let range: (Token, Token)
  var storage: [String: Int] = [:]

  init(range: (Token, Token), system: ActorSystem) {
    self.range = range
  }

  // $s4main10TokenRangeC6coversySbAA0B0VFTE
  distributed func covers(_ token: Token) -> Bool {
    return token >= range.0 && range.1 < token
  }

  // $s4main10TokenRangeC6insertySiSgSS_SitFTE
  distributed func insert(_ key: String, _ value: Int) -> Int? {
    assert(covers(Token.from(string: key)))

    let prev = storage[key]
    storage[key] = value
    return prev
  }

  // $s4main10TokenRangeC5fetchySiSgSSKFTE
  distributed func fetch(_ key: String) throws -> Int? {
    assert(covers(Token.from(string: key)))
    return storage[key]
  }

  nonisolated var description: String {
    "\(Self.self)(\(self.id))"
  }
}

extension TokenRange {

  // TODO: We'll synthesize IN the _remote_... thunks and remove the dynamic replacement mechanism entirely.
  @_dynamicReplacement(for: _remote_covers(_:))
  nonisolated func _remote_impl_covers(_ token: Token) async throws -> Bool {
    let mangledName = "$s4main10TokenRangeC6coversySbAA0B0VFTE"

    print("\(#function): prepare invocation...")
    var invocation = self.actorSystem.makeInvocation()
    try invocation.recordArgument(argument: token)
    try invocation.recordReturnType(mangledType: Bool.self) // FIXME: so... we truly want to pass mangled like that?
    try invocation.doneRecording()
    print("\(#function): invocation ready.")

    let target = RemoteCallTarget(_mangledName: mangledName)

    print("\(#function): make remoteCall...")
    return try await self.actorSystem.remoteCall(
        on: self,
        target: target,
        invocation: invocation,
        throwing: Never.self,
        returning: Bool.self
    )
  }
}

distributed actor TokenRing: CustomStringConvertible {
  typealias ActorSystem = InProcessSystem

  var ranges: [TokenRange] = []

  init(system: ActorSystem) {
    print("Initialized: \(self.id)")
  }

  deinit {
    print("Deinitialized: \(self.id)")
  }

  // $s4main9TokenRingC6insertySiSgSS_SitYaKFTE
  distributed func insert(_ key: String, _ value: Int) async throws -> Int? {
    let token = Token.from(string: key)
    return try await findRange(for: token)?.insert(key, value)
  }

  // $s4main9TokenRingC5fetchySiSgSSYaKFTE
  distributed func fetch(_ key: String) async throws -> Int? {
    let token = Token.from(string: key)
    return try await findRange(for: token)?.fetch(key)
  }

  // $s4main9TokenRingC8registeryyAA0B5RangeCFTE
  distributed func register(_ range: TokenRange) {
    // TODO: Check whether this range anything already in the ring.
    ranges.append(range)
  }

  private func findRange(`for` token: Token) async throws -> TokenRange? {
    print("\(id) - findRange(for: \(token)):")
    for range in ranges {
      print("\(id) - findRange(for: \(token)): \(range) covers \(token)...?")
      if try await range.covers(token) {
        print("\(id) - findRange(for: \(token)): \(range) covers \(token)! return")
        return range
      }
    }
    return nil
  }

  nonisolated var description: String {
    "\(Self.self)(\(self.id))"
  }
}

@_silgen_name("swift_distributed_actor_is_remote")
func __isRemoteActor(_ actor: AnyObject) -> Bool

@main
struct Test {
  static func main() async throws {
    let system = InProcessSystem()
    let remote = InProcessSystem()

    func makeRemoteRange(from start: Token, to end: Token) throws -> TokenRange {
      let local = TokenRange(range: (start, end), system: remote)
      let remote = try TokenRange.resolve(id: local.id, using: system)
      // ensure we indeed got back remote references
      assert(__isRemoteActor(remote))
      return remote
    }

    let ring = TokenRing(system: system)
    let range1 = try makeRemoteRange(from: .init(0), to: .init(255))
    let range2 = try makeRemoteRange(from: .init(256), to: .init(0))

    try await ring.register(range1)
    try await ring.register(range2)

    let prev = try await ring.insert("ultimate answer", 42)
    let curr = try await ring.fetch("ultimate answer")

    print("curr: \(curr)") // CHECK: curr: 42
    assert(prev == nil)
    assert(curr == 42)

  }
}
