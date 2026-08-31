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

// A reusable in-memory `DistributedActorSystem` for Embedded Swift runtime
// tests. It plays both ends of a call in-process, but it forces the payload
// through a real serialized wire format rather than sharing mutable state: the
// encoder builds a byte payload, `remoteCall` copies it "across the network"
// into a fresh decoder, the callee's result handler serializes its return value
// into a separate response payload, and that in turn is copied back "across the
// network" into the decoder the caller reads from. The two directions use
// distinct buffer types (`CallBuffer` / `ResultBuffer`) so each crossing is
// explicit.
//
// The wire is a raw `[UInt8]` treated as ASCII: no `String` grapheme or
// normalization operations are used anywhere in the transport, so the test
// links without the Unicode data tables. The only `String` values are the
// argument and return payloads themselves, which cross as their UTF-8 bytes.
//
// This mirrors `FakeRoundtripActorSystem` from the non-embedded tests, with one
// forced difference. The non-embedded system stores `any DistributedActor` and
// dispatches by `_openExistential` + the runtime `executeDistributedTarget(on:)`
// entrypoint. Neither exists under Embedded Swift: opening an existential is
// rejected, and there is no metadata-driven dispatch (every actor gets a
// monomorphized `_executeDistributedTarget` instead). So the value stored per id
// is that actor's receive entrypoint - a thunk closing over the concrete actor -
// registered in `actorReady(_:)`, whose embedded `Act.ActorSystem == Self`
// requirement is what lets it form the call.

import _Concurrency
import Distributed

// ==== ----------------------------------------------------------------------
// MARK: A tiny ASCII wire format
//
// Every value is serialized as one ";"-terminated "<tag>|<bytes>" field, where
// the tag is a single ASCII byte naming the type: "s" for String, "i" for Int.
// `recordArgument` appends fields to a request payload; `onReturn` writes a
// single response field. A real transport would frame and length-prefix bytes;
// a flat byte array keeps the test legible while still forcing an
// encode -> transmit -> decode round-trip.
//
// The framing primitives (`appendField` / `takeField` / `writeResponse`) and
// `WireError` are public, so a module that introduces its own argument or
// return type can add the matching `recordArgument` / `decodeNextArgument` /
// `onReturn` overloads in its own file - see `GreeterAPI` adding overloads for
// `ComplexRequest` / `ComplexResponse`. This is the Embedded serialization
// contract: there is no `SerializationRequirement`, just per-type overloads the
// compiler finds by normal extension visibility.

private let tagString = UInt8(ascii: "s")
private let tagInt = UInt8(ascii: "i")
private let sep = UInt8(ascii: "|")
private let term = UInt8(ascii: ";")

// Render an `Int` as its decimal ASCII bytes, without going through `String`.
// Public so other modules can serialize integer fields of their own types
public func asciiDigits(_ value: Int) -> [UInt8] {
  if value == 0 { return [UInt8(ascii: "0")] }
  var v = value
  let negative = v < 0
  var digits: [UInt8] = []
  // Build least-significant digit first, then reverse
  while v != 0 {
    let d = v % 10
    // Works for negative v too: -(d) is a single digit 0...9
    digits.append(UInt8(ascii: "0") + UInt8(d < 0 ? -d : d))
    v /= 10
  }
  if negative { digits.append(UInt8(ascii: "-")) }
  return Array(digits.reversed())
}

// Parse decimal ASCII bytes back into an `Int`, without going through `String`.
// Public so other modules can deserialize integer fields of their own types
public func parseInt(_ bytes: ArraySlice<UInt8>) -> Int? {
  if bytes.isEmpty { return nil }
  var result = 0
  var negative = false
  var idx = bytes.startIndex
  if bytes[idx] == UInt8(ascii: "-") {
    negative = true
    idx = bytes.index(after: idx)
    if idx == bytes.endIndex { return nil }
  }
  while idx != bytes.endIndex {
    let b = bytes[idx]
    guard b >= UInt8(ascii: "0"), b <= UInt8(ascii: "9") else { return nil }
    result = result * 10 + Int(b - UInt8(ascii: "0"))
    idx = bytes.index(after: idx)
  }
  return negative ? -result : result
}

// The request payload. The caller's encoder serializes arguments into
// `argBytes`; that array is what crosses the network to the callee, which
// rebuilds its own decoder from a copy of it
final class CallBuffer {
  var argBytes: [UInt8] = []
  init() {}
}

// The response payload. The callee's result handler serializes the return value
// into `returnBytes`; that array crosses the network back to the caller
final class ResultBuffer {
  var returnBytes: [UInt8] = []
  init() {}
}

// Thrown by the decoder when the incoming wire does not match what the
// monomorphized `decodeNextArgument` overload expects
public enum WireError: Error {
  case underflow
  case malformed
  case typeMismatch
  case badValue
}

// ==== ----------------------------------------------------------------------
// MARK: Encoder / Decoder / ResultHandler

public struct EmbeddedFakeInvocationEncoder: DistributedTargetInvocationEncoder {
  let buffer: CallBuffer
  init(buffer: CallBuffer) { self.buffer = buffer }
  public mutating func doneRecording() throws {}
}
extension EmbeddedFakeInvocationEncoder {
  public mutating func recordArgument(_ argument: RemoteCallArgument<String>) throws {
    appendField(tag: tagString, payload: Array(argument.value.utf8))
  }
  public mutating func recordArgument(_ argument: RemoteCallArgument<Int>) throws {
    appendField(tag: tagInt, payload: asciiDigits(argument.value))
  }

  // Append one "<tag>|<payload>;" field to the request wire. Public so other
  // modules can serialize their own argument types (see GreeterAPI)
  public func appendField(tag: UInt8, payload: [UInt8]) {
    buffer.argBytes.append(tag)
    buffer.argBytes.append(sep)
    buffer.argBytes.append(contentsOf: payload)
    buffer.argBytes.append(term)
  }
}

public struct EmbeddedFakeInvocationDecoder: DistributedTargetInvocationDecoder {
  let buffer: CallBuffer
  // Read cursor into `buffer.argBytes`; each `decodeNextArgument` advances it
  var offset: Int = 0
  init(buffer: CallBuffer) { self.buffer = buffer }
}

extension EmbeddedFakeInvocationDecoder {
  public mutating func decodeNextArgument(_ type: String.Type) throws -> String {
    let (tag, payload) = try takeField()
    guard tag == tagString else { throw WireError.typeMismatch }
    return String(decoding: payload, as: UTF8.self)
  }
  public mutating func decodeNextArgument(_ type: Int.Type) throws -> Int {
    let (tag, payload) = try takeField()
    guard tag == tagInt else { throw WireError.typeMismatch }
    guard let n = parseInt(payload) else { throw WireError.badValue }
    return n
  }

  // Peel one "<tag>|<bytes>" field off the front of the incoming wire, leaving
  // the remainder for the next call. The trailing ";" is optional on the final
  // field, so a lone response value decodes without a terminator. Public so
  // other modules can deserialize their own types (see GreeterAPI)
  public mutating func takeField() throws -> (tag: UInt8, payload: ArraySlice<UInt8>) {
    let bytes = buffer.argBytes
    guard offset < bytes.count else { throw WireError.underflow }
    let tag = bytes[offset]
    let sepIdx = offset + 1
    guard sepIdx < bytes.count, bytes[sepIdx] == sep else {
      throw WireError.malformed
    }
    var i = sepIdx + 1
    let payloadStart = i
    while i < bytes.count, bytes[i] != term {
      i += 1
    }
    let payload = bytes[payloadStart..<i]
    // Consume the terminator if present; otherwise stop at end of buffer
    offset = (i < bytes.count) ? i + 1 : i
    return (tag, payload)
  }
}

public struct EmbeddedFakeResultHandler: DistributedTargetInvocationResultHandler {
  let buffer: ResultBuffer
  init(buffer: ResultBuffer) { self.buffer = buffer }
  public func onReturnVoid() async throws { buffer.returnBytes = [] }
  public func onThrow(error: any Error) async throws {
    fatalError("threw in handler")
  }

  // Serialize the single response field. Symmetric with the encoder's
  // `appendField`; public so other modules can add `onReturn` overloads for
  // their own return types (see GreeterAPI)
  public func writeResponse(tag: UInt8, payload: [UInt8]) {
    buffer.returnBytes = [tag, sep] + payload
  }
}
extension EmbeddedFakeResultHandler {
  public func onReturn(_ value: String) async throws {
    writeResponse(tag: tagString, payload: Array(value.utf8))
  }
  public func onReturn(_ value: Int) async throws {
    writeResponse(tag: tagInt, payload: asciiDigits(value))
  }
}

// ==== ----------------------------------------------------------------------
// MARK: The actor system

public struct EmbeddedFakeActorID: Sendable, Hashable {
  public let id: UInt64
  public init(id: UInt64) { self.id = id }
}

public final class EmbeddedFakeRoundtripActorSystem: DistributedActorSystem, @unchecked Sendable {
  public typealias ActorID = EmbeddedFakeActorID
  public typealias InvocationEncoder = EmbeddedFakeInvocationEncoder
  public typealias InvocationDecoder = EmbeddedFakeInvocationDecoder
  public typealias ResultHandler = EmbeddedFakeResultHandler

  // Each hosted actor's monomorphized receive entrypoint, keyed by id, filled in
  // by `actorReady`. See the file comment for why this is a thunk rather than an
  // `any DistributedActor`
  public typealias LocalDispatch =
    (RemoteCallTarget, inout InvocationDecoder, ResultHandler) async throws -> Void

  var active: [ActorID: LocalDispatch] = [:]
  var nextID: UInt64 = 1

  public init() {}

  public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
      where Act: DistributedActor, Act.ActorSystem == EmbeddedFakeRoundtripActorSystem {
    return nil // always remote: calls route through `remoteCall`
  }
  public func assignID<Act>(_ actorType: Act.Type) -> ActorID
      where Act: DistributedActor, Act.ActorSystem == EmbeddedFakeRoundtripActorSystem {
    defer { nextID += 1 }
    return ActorID(id: nextID)
  }

  // Register the locally-hosted actor's receive entrypoint, keyed by id. The
  // synthesized designated initializer calls `actorReady(self)` once the actor
  // is fully initialized, so hosting happens automatically - the use site never
  // registers the actor explicitly.
  //
  // The embedded `actorReady` requirement is constrained to
  // `Act.ActorSystem == Self` (not just `Act.ID == ActorID`), which is what lets
  // us form the call to `_executeDistributedTarget`: its decoder/handler are
  // `Act.ActorSystem.InvocationDecoder` / `.ResultHandler`, which only unify with
  // our `InvocationDecoder` / `ResultHandler` when the actor's system is known to
  // be this one. The witness spells `Self` out as the concrete
  // `EmbeddedFakeRoundtripActorSystem`: inside a class, `Self` is the dynamic
  // `Self` type, and `Act.ActorSystem == Self` against it builds a contradictory
  // signature - naming the concrete type matches the substituted requirement
  public func actorReady<Act>(_ actor: Act)
      where Act: DistributedActor, Act.ActorSystem == EmbeddedFakeRoundtripActorSystem {
    active[actor.id] = { target, decoder, handler in
      try await actor._executeDistributedTarget(
          target: target, invocationDecoder: &decoder, resultHandler: handler)
    }
  }
  public func resignID(_ id: ActorID) {}

  public func makeInvocationEncoder() -> InvocationEncoder { .init(buffer: CallBuffer()) }

  public func remoteCall<Act>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder
  ) async throws -> InvocationDecoder
      where Act: DistributedActor, Act.ActorSystem == EmbeddedFakeRoundtripActorSystem {
    print("[swift] remoteCall reached")
    guard let dispatch = active[actor.id] else {
      fatalError("no local actor hosted for the target id")
    }

    // The caller's encoder holds the fully serialized arguments. Read them out
    // as the request payload and hand a copy to the callee - the array value
    // copy is the "network": the callee gets its own buffer, not a shared ref
    let requestWire = invocation.buffer.argBytes
    // ==================== NETWORK: request -> callee =====================
    let requestBuffer = CallBuffer()
    requestBuffer.argBytes = requestWire
    var decoder = InvocationDecoder(buffer: requestBuffer)

    // The callee decodes its arguments from `decoder`, runs the target, and
    // serializes its return value into this response buffer
    let resultBuffer = ResultBuffer()
    let handler = ResultHandler(buffer: resultBuffer)
    try await dispatch(target, &decoder, handler)

    // Take the serialized response back across the wire and rebuild the decoder
    // the caller reads its return value from
    let responseWire = resultBuffer.returnBytes

    // ==================== NETWORK: response -> caller ====================

    let responseBuffer = CallBuffer()
    responseBuffer.argBytes = responseWire
    return InvocationDecoder(buffer: responseBuffer)
  }

  public func remoteCallVoid<Act>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder
  ) async throws
      where Act: DistributedActor, Act.ActorSystem == EmbeddedFakeRoundtripActorSystem {
    print("[swift] remoteCallVoid reached")
    guard let dispatch = active[actor.id] else {
      fatalError("no local actor hosted for the target id")
    }

    // Same request crossing as `remoteCall`: hand the callee a copy of the
    // serialized arguments over the wire
    let requestWire = invocation.buffer.argBytes
    // ==================== NETWORK: request -> callee =====================
    let requestBuffer = CallBuffer()
    requestBuffer.argBytes = requestWire
    var decoder = InvocationDecoder(buffer: requestBuffer)

    // The callee decodes its arguments and runs the target. A void target
    // resolves through the handler's `onReturnVoid`, which writes an empty
    // response - there is nothing to read back, so unlike `remoteCall` this
    // returns no decoder
    let resultBuffer = ResultBuffer()
    let handler = ResultHandler(buffer: resultBuffer)
    try await dispatch(target, &decoder, handler)
  }
}
