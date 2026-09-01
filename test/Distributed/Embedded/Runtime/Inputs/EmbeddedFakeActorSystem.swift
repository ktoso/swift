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
// network" and decoded into the caller's `Res`.
//
// The wire is a raw `[UInt8]` treated as ASCII: no `String` grapheme or
// normalization operations are used anywhere in the transport, so the test
// links without the Unicode data tables. Argument and return payloads only ever
// cross as raw bytes.
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
// MARK: The serialization requirement
//
// Under Embedded Swift `DistributedActorSystem` still carries a
// `SerializationRequirement` associated type, but the concrete system chooses
// what protocol binds it (Embedded can't use `Codable`). This system binds it
// to `EmbeddedSerializationRequirement`: a byte-oriented protocol that
// serializes a value into an `OutputSpan<UInt8>` and reconstructs it from a
// borrowed `Span<UInt8>`. The compiler enforces that every argument and return
// type of a `distributed func` conforms to it, and the encoder / decoder /
// handler serialize conforming values through a single generic method rather
// than per-type overloads.

public protocol EmbeddedSerializationRequirement {
  // The exact number of bytes `encode(into:)` will append. The encoder reserves
  // this much non-growing capacity up front, since `OutputSpan` appends into
  // reserved storage rather than growing it
  var serializedByteCount: Int { get }

  // Append exactly `serializedByteCount` bytes describing this value
  func encode(into output: inout OutputSpan<UInt8>)

  // Reconstruct a value by consuming bytes off the front of `input`, advancing
  // it past what was read
  static func decode(from input: inout Span<UInt8>) throws -> Self
}

// ==== ----------------------------------------------------------------------
// MARK: A tiny length-prefixed wire format
//
// Every value is serialized as one "<decimal-byte-count>|<payload>" field: the
// payload's length in decimal ASCII, a "|" separator, then exactly that many
// payload bytes. `recordArgument` appends one field per argument; `onReturn`
// writes a single response field. The length prefix is what lets the decoder
// find each field's boundary without a type tag, since the type is known
// statically at each specialized call site.
//
// The integer codec (`asciiDigits` / `parseInt`) and the span-draining helper
// (`drain`) are public so a module that introduces its own argument or return
// type can conform it to `EmbeddedSerializationRequirement` in its own file -
// see `GreeterAPI` conforming `ComplexRequest` / `ComplexResponse`.

private let sep = UInt8(ascii: "|")

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

// Copy all remaining bytes of a borrowed `Span` into an owned array and advance
// the span past them. Public so other modules can implement `decode(from:)` for
// their own types without touching `Span`'s element API directly
public func drain(_ input: inout Span<UInt8>) -> [UInt8] {
  let n = input.count
  var out: [UInt8] = []
  out.reserveCapacity(n)
  var i = 0
  while i < n {
    out.append(input[i])
    i += 1
  }
  input = input.extracting(droppingFirst: n)
  return out
}

// ==== ----------------------------------------------------------------------
// MARK: Serialization conformances for the built-in payload types

extension String: EmbeddedSerializationRequirement {
  public var serializedByteCount: Int { utf8.count }
  public func encode(into output: inout OutputSpan<UInt8>) {
    for byte in utf8 { output.append(byte) }
  }
  public static func decode(from input: inout Span<UInt8>) throws -> String {
    String(decoding: drain(&input), as: UTF8.self)
  }
}

extension Int: EmbeddedSerializationRequirement {
  public var serializedByteCount: Int { asciiDigits(self).count }
  public func encode(into output: inout OutputSpan<UInt8>) {
    for byte in asciiDigits(self) { output.append(byte) }
  }
  public static func decode(from input: inout Span<UInt8>) throws -> Int {
    let bytes = drain(&input)
    guard let n = parseInt(bytes[...]) else { throw WireError.badValue }
    return n
  }
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

// Thrown by the decoder when the incoming wire is malformed or a payload does
// not parse into the expected type
public enum WireError: Error {
  case underflow
  case malformed
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
  // The single generic record method. The synthesized distributed thunk emits a
  // specialized call to it for each argument; there are no per-type overloads
  public mutating func recordArgument<Value: EmbeddedSerializationRequirement>(
      _ argument: RemoteCallArgument<Value>) throws {
    appendField(argument.value)
  }

  // Append one length-prefixed field to the request wire: the payload's byte
  // count as decimal ASCII, a "|" separator, then exactly that many payload
  // bytes written straight into freshly reserved array capacity through an
  // `OutputSpan`. Generic over the serialization protocol, so any conforming
  // type serializes the same way
  public func appendField<Value: EmbeddedSerializationRequirement>(_ value: Value) {
    let n = value.serializedByteCount
    buffer.argBytes.append(contentsOf: asciiDigits(n))
    buffer.argBytes.append(sep)
    buffer.argBytes.append(addingCapacity: n) { output in
      value.encode(into: &output)
    }
  }
}

public struct EmbeddedFakeInvocationDecoder: DistributedTargetInvocationDecoder {
  let buffer: CallBuffer
  // Read cursor into `buffer.argBytes`; each `decodeNextArgument` advances it
  var offset: Int = 0
  init(buffer: CallBuffer) { self.buffer = buffer }
}

extension EmbeddedFakeInvocationDecoder {
  // The single generic decode method. `Argument` is inferred from the call
  // context (the parameter type on the receiver side, or the `Res` the sender's
  // `remoteCall` is decoding); the thunk / system emit specialized calls
  public mutating func decodeNextArgument<Argument: EmbeddedSerializationRequirement>() throws -> Argument {
    let payload = try takeField()
    let owned = Array(payload)
    var span = owned.span
    return try Argument.decode(from: &span)
  }

  // Peel one length-prefixed field off the front of the incoming wire,
  // returning its payload bytes and advancing the read cursor past them. Public
  // so other modules' `decode(from:)` conformances can reuse the framing
  public mutating func takeField() throws -> ArraySlice<UInt8> {
    let bytes = buffer.argBytes
    guard offset < bytes.count else { throw WireError.underflow }
    var i = offset
    while i < bytes.count, bytes[i] != sep { i += 1 }
    guard i < bytes.count else { throw WireError.malformed }
    guard let n = parseInt(bytes[offset..<i]), n >= 0 else { throw WireError.malformed }
    let start = i + 1
    let end = start + n
    guard end <= bytes.count else { throw WireError.underflow }
    offset = end
    return bytes[start..<end]
  }
}

public struct EmbeddedFakeResultHandler: DistributedTargetInvocationResultHandler {
  let buffer: ResultBuffer
  init(buffer: ResultBuffer) { self.buffer = buffer }
  public func onReturnVoid() async throws { buffer.returnBytes = [] }
  public func onThrow(error: any Error) async throws {
    fatalError("threw in handler")
  }

  // Serialize the single response field, length-prefixed like the request
  // fields. Symmetric with the encoder's `appendField`
  public func writeResponse<Value: EmbeddedSerializationRequirement>(_ value: Value) {
    let n = value.serializedByteCount
    var out: [UInt8] = []
    out.append(contentsOf: asciiDigits(n))
    out.append(sep)
    out.append(addingCapacity: n) { output in
      value.encode(into: &output)
    }
    buffer.returnBytes = out
  }
}
extension EmbeddedFakeResultHandler {
  // The single generic result method. The synthesized receive-dispatch emits a
  // specialized call to it with the distributed func's return value
  public func onReturn<Success: EmbeddedSerializationRequirement>(_ value: Success) async throws {
    writeResponse(value)
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
  public typealias SerializationRequirement = EmbeddedSerializationRequirement
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

  // Perform the call and return its decoded result. Unlike the non-embedded
  // shape there is no `throwing:` / `returning:` metatype parameter and no
  // decoder handed back to the thunk: `Res` is inferred from the call context
  // and this method is responsible for decoding the response wire into it
  public func remoteCall<Act, Res>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder
  ) async throws -> Res
      where Act: DistributedActor,
            Act.ID == ActorID,
            Res: EmbeddedSerializationRequirement {
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

    // Take the serialized response back across the wire and decode it into `Res`
    let responseWire = resultBuffer.returnBytes
    // ==================== NETWORK: response -> caller ====================
    let responseBuffer = CallBuffer()
    responseBuffer.argBytes = responseWire
    var responseDecoder = InvocationDecoder(buffer: responseBuffer)
    return try responseDecoder.decodeNextArgument()
  }

  public func remoteCallVoid<Act>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder
  ) async throws
      where Act: DistributedActor, Act.ID == ActorID {
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
    // response - there is nothing to read back
    let resultBuffer = ResultBuffer()
    let handler = ResultHandler(buffer: resultBuffer)
    try await dispatch(target, &decoder, handler)
  }
}
