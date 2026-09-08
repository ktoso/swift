//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

// A reusable in-memory `DistributedActorSystem` that plays both ends of a call
// in-process but forces every argument and return value through a REAL
// serialized `[UInt8]` wire: the encoder renders each value to bytes, the bytes
// are copied "across the network" into a fresh buffer the far end owns, and the
// far end decodes them back independently. Nothing is passed by shared
// reference or cast through `Any`. If any encode / decode step were wrong the
// value would not survive the trip.
//
// The SAME source compiles both with and without Embedded Swift. Only the
// per-value (de)serialization and the `remoteCall` family shape differ between
// the modes, and those live behind `#if $Embedded`:
//
//   - Embedded has no `Codable`, so `SerializationRequirement` binds to a tiny
//     byte protocol whose conformers render to raw UTF-8 bytes, `remoteCall`
//     drops the `<Err>` generic and the `throwing:`/`returning:` metatype
//     parameters, and the receiver runs on the concrete local actor's
//     monomorphized `_executeDistributedTarget` (kept as a per-id closure,
//     since Embedded has no existential-opening or metadata-driven dispatch).
//   - Ordinary Swift binds `SerializationRequirement` to `Codable`, serializes
//     with Foundation's JSON coders, keeps the full `remoteCall` signature, and
//     dispatches through `_openExistential` + the metadata-driven
//     `executeDistributedTarget`.
//
// The system is actor-agnostic - it never names a concrete actor type - so any
// portable test can declare its own `distributed actor` against it.

import _Concurrency
import Distributed

// ==== ----------------------------------------------------------------------
// MARK: Shared byte-wire framing (identical in both modes)
//
// A value crosses as one length-prefixed field: "<decimal-byte-count>|<bytes>".
// The length prefix lets the decoder find each field boundary without a type
// tag, since the expected type is known statically at each call site. All of
// this is plain `[UInt8]` arithmetic - no `String` grapheme work - so it links
// under Embedded without the Unicode data tables.

private let fieldSeparator = UInt8(ascii: "|")

// Render an `Int` as decimal ASCII bytes without going through `String`.
public func asciiDigits(_ value: Int) -> [UInt8] {
  if value == 0 { return [UInt8(ascii: "0")] }
  var v = value
  var digits: [UInt8] = []
  while v != 0 {
    digits.append(UInt8(ascii: "0") + UInt8(v % 10))
    v /= 10
  }
  return Array(digits.reversed())
}

// Parse decimal ASCII bytes back into an `Int` without going through `String`.
public func parseInt(_ bytes: ArraySlice<UInt8>) -> Int? {
  if bytes.isEmpty { return nil }
  var result = 0
  for b in bytes {
    guard b >= UInt8(ascii: "0"), b <= UInt8(ascii: "9") else { return nil }
    result = result * 10 + Int(b - UInt8(ascii: "0"))
  }
  return result
}

// Append one length-prefixed field to `wire`.
public func appendField(_ payload: [UInt8], to wire: inout [UInt8]) {
  wire.append(contentsOf: asciiDigits(payload.count))
  wire.append(fieldSeparator)
  wire.append(contentsOf: payload)
}

// Peel one length-prefixed field off `wire`, advancing `offset` past it.
public func takeField(_ wire: [UInt8], _ offset: inout Int) -> [UInt8]? {
  guard offset < wire.count else { return nil }
  var i = offset
  while i < wire.count, wire[i] != fieldSeparator { i += 1 }
  guard i < wire.count, let n = parseInt(wire[offset..<i]), n >= 0 else { return nil }
  let start = i + 1
  let end = start + n
  guard end <= wire.count else { return nil }
  offset = end
  return Array(wire[start..<end])
}

// The request / response payload. `remoteCall` copies the bytes out of one of
// these into a brand-new one for the far end - that copy is the "network".
public final class CallBuffer {
  public var argBytes: [UInt8] = []
  public var returnBytes: [UInt8] = []
  public init() {}
}

// UInt64-backed on purpose: a String-backed id would risk pulling the Unicode
// data tables into the embedded link. Ids never appear on the wire.
public struct PortableActorID: Sendable, Hashable {
  public let id: UInt64
  public init(id: UInt64) { self.id = id }
}

#if $Embedded

// ==== ----------------------------------------------------------------------
// MARK: Embedded per-value serialization

// Embedded can't use `Codable`; the system binds `SerializationRequirement` to
// this byte protocol and conforming types render straight to UTF-8 bytes. This
// system only moves `String`, so that is all that conforms.
public protocol PortableSerializationRequirement {
  func toWireBytes() -> [UInt8]
  // Decode takes the actor system so that distributed-actor references can be
  // reconstructed by resolving their id - the embedded analog of Codable's
  // `decoder.userInfo[.actorSystemKey]`. `throws` so `resolve` can propagate;
  // value types (like `String`) just ignore the system and never throw.
  static func fromWireBytes(_ bytes: [UInt8],
                            system: PortableRoundtripActorSystem) throws -> Self
}
extension String: PortableSerializationRequirement {
  public func toWireBytes() -> [UInt8] { Array(utf8) }
  public static func fromWireBytes(_ bytes: [UInt8],
                                   system: PortableRoundtripActorSystem) -> String {
    String(decoding: bytes, as: UTF8.self)
  }
}

public struct PortableEncoder: DistributedTargetInvocationEncoder {
  let buffer: CallBuffer
  init(buffer: CallBuffer) { self.buffer = buffer }
  public mutating func doneRecording() throws {}
}
extension PortableEncoder {
  public mutating func recordArgument<Value: PortableSerializationRequirement>(
      _ argument: RemoteCallArgument<Value>) throws {
    appendField(argument.value.toWireBytes(), to: &buffer.argBytes)
  }
}

public struct PortableDecoder: DistributedTargetInvocationDecoder {
  let buffer: CallBuffer
  var offset = 0
  // The decoder carries the actor system so that a distributed-actor argument
  // can be resolved from its serialized id (see `fromWireBytes`).
  let system: PortableRoundtripActorSystem
  init(buffer: CallBuffer, system: PortableRoundtripActorSystem) {
    self.buffer = buffer
    self.system = system
  }
}
extension PortableDecoder {
  public mutating func decodeNextArgument<Argument: PortableSerializationRequirement>() throws -> Argument {
    guard let field = takeField(buffer.argBytes, &offset) else { fatalError("wire underflow") }
    return try Argument.fromWireBytes(field, system: system)
  }
}

public struct PortableResultHandler: DistributedTargetInvocationResultHandler {
  let buffer: CallBuffer
  init(buffer: CallBuffer) { self.buffer = buffer }
  public func onReturnVoid() async throws {}
  public func onThrow(error: any Error) async throws { fatalError("threw in handler") }
}
extension PortableResultHandler {
  public func onReturn<Success: PortableSerializationRequirement>(_ value: Success) async throws {
    appendField(value.toWireBytes(), to: &buffer.returnBytes)
  }
}

public final class PortableRoundtripActorSystem: DistributedActorSystem, @unchecked Sendable {
  public typealias ActorID = PortableActorID
  public typealias SerializationRequirement = PortableSerializationRequirement
  public typealias InvocationEncoder = PortableEncoder
  public typealias InvocationDecoder = PortableDecoder
  public typealias ResultHandler = PortableResultHandler

  // Each hosted actor's monomorphized receive entrypoint, keyed by id. Embedded
  // has no existential-opening or metadata dispatch, so instead of storing an
  // `any DistributedActor` we store a thunk that closes over the concrete actor.
  public typealias LocalDispatch =
    (RemoteCallTarget, inout InvocationDecoder, ResultHandler) async throws -> Void
  var active: [ActorID: LocalDispatch] = [:]
  var nextID: UInt64 = 1

  public init() {}

  public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
      where Act: DistributedActor, Act.ActorSystem == PortableRoundtripActorSystem {
    return nil // always resolve as remote: calls route through remoteCall
  }
  public func assignID<Act>(_ actorType: Act.Type) -> ActorID
      where Act: DistributedActor, Act.ActorSystem == PortableRoundtripActorSystem {
    defer { nextID += 1 }
    return ActorID(id: nextID)
  }
  public func actorReady<Act>(_ actor: Act)
      where Act: DistributedActor, Act.ActorSystem == PortableRoundtripActorSystem {
    active[actor.id] = { target, decoder, handler in
      try await actor._executeDistributedTarget(
          target: target, invocationDecoder: &decoder, resultHandler: handler)
    }
  }
  public func resignID(_ id: ActorID) {}
  public func makeInvocationEncoder() -> InvocationEncoder { .init(buffer: CallBuffer()) }

  public func remoteCall<Act, Res>(
    on actor: Act, target: RemoteCallTarget, invocation: inout InvocationEncoder
  ) async throws -> Res
      where Act: DistributedActor, Act.ID == ActorID, Res: SerializationRequirement {
    print("[swift] remoteCall reached")
    guard let dispatch = active[actor.id] else { fatalError("no local actor hosted") }
    // ==================== NETWORK: request bytes -> callee ====================
    let requestBuffer = CallBuffer()
    requestBuffer.argBytes = invocation.buffer.argBytes // value-type copy of the bytes
    var decoder = PortableDecoder(buffer: requestBuffer, system: self)
    let handler = PortableResultHandler(buffer: requestBuffer)
    try await dispatch(target, &decoder, handler)
    // ==================== NETWORK: response bytes -> caller ===================
    let responseBuffer = CallBuffer()
    responseBuffer.argBytes = requestBuffer.returnBytes
    var responseDecoder = PortableDecoder(buffer: responseBuffer, system: self)
    return try responseDecoder.decodeNextArgument()
  }

  public func remoteCallVoid<Act>(
    on actor: Act, target: RemoteCallTarget, invocation: inout InvocationEncoder
  ) async throws where Act: DistributedActor, Act.ID == ActorID {
    fatalError("not exercised by portable roundtrip tests")
  }
}

#else

// ==== ----------------------------------------------------------------------
// MARK: Ordinary-Swift per-value serialization

// Ordinary Swift binds `SerializationRequirement` to `Codable` and does a
// genuine encode/decode with Foundation's JSON coders. The value is boxed so
// the top level is always a JSON object (avoids top-level-fragment concerns).
import Foundation

struct Box<T: Codable>: Codable { let value: T }

func toWireBytes<T: Codable>(_ value: T) -> [UInt8] {
  Array(try! JSONEncoder().encode(Box(value: value)))
}
func fromWireBytes<T: Codable>(_ bytes: [UInt8], as type: T.Type) -> T {
  try! JSONDecoder().decode(Box<T>.self, from: Data(bytes)).value
}

public struct PortableEncoder: DistributedTargetInvocationEncoder {
  public typealias SerializationRequirement = Codable
  let buffer: CallBuffer
  init(buffer: CallBuffer) { self.buffer = buffer }
  public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {}
  public mutating func recordArgument<Value: Codable>(_ argument: RemoteCallArgument<Value>) throws {
    appendField(toWireBytes(argument.value), to: &buffer.argBytes)
  }
  public mutating func recordReturnType<R: Codable>(_ type: R.Type) throws {}
  public mutating func recordErrorType<E: Error>(_ type: E.Type) throws {}
  public mutating func doneRecording() throws {}
}

public final class PortableDecoder: DistributedTargetInvocationDecoder {
  public typealias SerializationRequirement = Codable
  let buffer: CallBuffer
  var offset = 0
  init(buffer: CallBuffer) { self.buffer = buffer }
  public func decodeGenericSubstitutions() throws -> [Any.Type] { [] }
  public func decodeNextArgument<Argument: Codable>() throws -> Argument {
    guard let field = takeField(buffer.argBytes, &offset) else { fatalError("wire underflow") }
    return fromWireBytes(field, as: Argument.self)
  }
  public func decodeReturnType() throws -> Any.Type? { nil }
  public func decodeErrorType() throws -> Any.Type? { nil }
}

public struct PortableResultHandler: DistributedTargetInvocationResultHandler {
  public typealias SerializationRequirement = Codable
  let buffer: CallBuffer
  init(buffer: CallBuffer) { self.buffer = buffer }
  public func onReturn<Success: Codable>(value: Success) async throws {
    appendField(toWireBytes(value), to: &buffer.returnBytes)
  }
  public func onReturnVoid() async throws {}
  public func onThrow<Err: Error>(error: Err) async throws { fatalError("threw in handler") }
}

public final class PortableRoundtripActorSystem: DistributedActorSystem, @unchecked Sendable {
  public typealias ActorID = PortableActorID
  public typealias SerializationRequirement = Codable
  public typealias InvocationEncoder = PortableEncoder
  public typealias InvocationDecoder = PortableDecoder
  public typealias ResultHandler = PortableResultHandler

  var activeActors: [ActorID: any DistributedActor] = [:]
  var nextID: UInt64 = 1

  public init() {}

  public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
      where Act: DistributedActor, Act.ID == ActorID {
    return nil // always resolve as remote: calls route through remoteCall
  }
  public func assignID<Act>(_ actorType: Act.Type) -> ActorID
      where Act: DistributedActor, Act.ID == ActorID {
    defer { nextID += 1 }
    return ActorID(id: nextID)
  }
  public func actorReady<Act>(_ actor: Act)
      where Act: DistributedActor, Act.ID == ActorID {
    activeActors[actor.id] = actor
  }
  public func resignID(_ id: ActorID) {}
  public func makeInvocationEncoder() -> InvocationEncoder { .init(buffer: CallBuffer()) }

  public func remoteCall<Act, Err, Res>(
    on actor: Act, target: RemoteCallTarget, invocation: inout InvocationEncoder,
    throwing errorType: Err.Type, returning returnType: Res.Type
  ) async throws -> Res
      where Act: DistributedActor, Act.ID == ActorID, Err: Error, Res: SerializationRequirement {
    print("[swift] remoteCall reached")
    guard let anyActor = activeActors[actor.id] else { fatalError("no local actor hosted") }
    // ==================== NETWORK: request bytes -> callee ====================
    let requestBuffer = CallBuffer()
    requestBuffer.argBytes = invocation.buffer.argBytes // value-type copy of the bytes
    let resultBuffer = CallBuffer()

    func doIt<A: DistributedActor>(active: A) async throws -> Res {
      var decoder = PortableDecoder(buffer: requestBuffer)
      let handler = PortableResultHandler(buffer: resultBuffer)
      try await executeDistributedTarget(
          on: active, target: target, invocationDecoder: &decoder, handler: handler)
      // ================== NETWORK: response bytes -> caller ==================
      let responseBuffer = CallBuffer()
      responseBuffer.argBytes = resultBuffer.returnBytes
      let responseDecoder = PortableDecoder(buffer: responseBuffer)
      return try responseDecoder.decodeNextArgument()
    }
    return try await _openExistential(anyActor, do: doIt)
  }

  public func remoteCallVoid<Act, Err>(
    on actor: Act, target: RemoteCallTarget, invocation: inout InvocationEncoder,
    throwing errorType: Err.Type
  ) async throws where Act: DistributedActor, Act.ID == ActorID, Err: Error {
    fatalError("not exercised by portable roundtrip tests")
  }
}

#endif

public typealias DefaultDistributedActorSystem = PortableRoundtripActorSystem
