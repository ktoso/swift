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

// The shared API contract, in its own module. `@Resolvable` generates the
// `$Greeter` proxy actor here; both the server (which conforms `GreeterImpl` to
// `Greeter`) and the client (which resolves and calls `$Greeter`) import this
// module. Neither the protocol nor `$Greeter` names a concrete implementation.

import Distributed
import EmbeddedFakeActorSystem

@Resolvable
public protocol Greeter: DistributedActor where ActorSystem == EmbeddedFakeRoundtripActorSystem {
  distributed func hello(name: String) -> String
  distributed func farewell(name: String) -> String

  distributed func note(_ message: String)

  distributed func check(_ uid: ComplexRequest) -> ComplexResponse
}


// ==== ---------------------------------------------------------------------------
// API module can declare whole API surface, including "complex" types.

public struct ComplexRequest: Sendable {
  public let id: Int
  public init(id: Int) { self.id = id }
}
public struct ComplexResponse: Sendable {
  public let id: Int
  public init(id: Int) { self.id = id }
}

// ==== ---------------------------------------------------------------------------
// As long as we also provide serialization for it:
//
// The transport (EmbeddedFakeActorSystem) does not know these types. Under
// Embedded Swift there is no `SerializationRequirement`; instead this module
// supplies the concrete `recordArgument` / `decodeNextArgument` / `onReturn`
// overloads for its own types, built on the transport's public framing
// primitives (`appendField` / `takeField` / `writeResponse`) and its integer
// codec (`asciiDigits` / `parseInt`). The compiler finds these overloads by
// ordinary extension visibility when it synthesizes the `$Greeter.check` /
// `GreeterImpl.check` thunks.
//
// Each type has a single `Int` field, serialized as the field payload under a
// module-owned tag byte.

private let tagComplexRequest = UInt8(ascii: "Q")
private let tagComplexResponse = UInt8(ascii: "P")

extension EmbeddedFakeInvocationEncoder {
  public mutating func recordArgument(_ argument: RemoteCallArgument<ComplexRequest>) throws {
    appendField(tag: tagComplexRequest, payload: asciiDigits(argument.value.id))
  }
}

extension EmbeddedFakeInvocationDecoder {
  // encode the request
  public mutating func decodeNextArgument(_ type: ComplexRequest.Type) throws -> ComplexRequest {
    let (tag, payload) = try takeField()
    guard tag == tagComplexRequest else { throw WireError.typeMismatch }
    guard let id = parseInt(payload) else { throw WireError.badValue }
    return ComplexRequest(id: id)
  }

  // we use this to decode a response
  public mutating func decodeNextArgument(_ type: ComplexResponse.Type) throws -> ComplexResponse {
    let (tag, payload) = try takeField()
    guard tag == tagComplexResponse else { throw WireError.typeMismatch }
    guard let id = parseInt(payload) else { throw WireError.badValue }
    return ComplexResponse(id: id)
  }
}

extension EmbeddedFakeResultHandler {
  public func onReturn(_ value: ComplexResponse) async throws {
    writeResponse(tag: tagComplexResponse, payload: asciiDigits(value.id))
  }
}
