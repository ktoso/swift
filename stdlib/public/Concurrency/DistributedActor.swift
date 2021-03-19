//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Swift
@_implementationOnly import _SwiftConcurrencyShims

/// Common protocol to which all distributed actors conform.
///
/// The \c DistributedActor protocol provides the core functionality of any
/// distributed actor, which involves transforming actor
/// which involves enqueuing new partial tasks to be executed at some
/// point. Actor classes implicitly conform to this protocol as part of their
/// primary class definition.
public protocol DistributedActor: Actor, Codable {
  associatedtype DistributedActorLocalStorage

  /// TODO: Customization point not implemented yet.
  ///
  /// A distributed actor requires all types involved in a 'distributed func'
  /// definition to conform to 'DistributedSendable'.
  ///
  /// It defaults to 'Codable', however specific transports may require that
  /// their actors conform to a specific different type and use highly specialized
  /// serialization mechanisms.
  typealias DistributedSendable = Codable // & Sendable

  /// Creates new (local) distributed actor instance, bound to the passed transport.
  ///
  /// Upon completion, the `actorAddress` field is populated by the transport,
  /// with an address assigned to this actor.
  ///
  /// - Parameter transport: transport which this actor should become associated with.
  ///
  /// ### Synthesis
  /// Implementation synthesized by the compiler.
  init(transport: ActorTransport)

  /// Resolves the passed in `address` against the `transport`,
  /// returning either a local or remote actor reference.
  ///
  /// The transport will be asked to `resolve` the address and return either
  /// a local instance or determine that a proxy instance should be created
  /// for this address. A proxy actor will forward all invocations through
  /// the transport, allowing it to take over the remote messaging with the
  /// remote actor instance.
  ///
  /// - Parameter address: the address to resolve, and produce an instance or proxy for.
  /// - Parameter transport: transport which should be used to resolve the `address`.
  ///
  /// ### Synthesis
  /// Implementation synthesized by the compiler.
  init(resolve address: ActorAddress, using transport: ActorTransport) throws

  /// The `ActorTransport` associated with this actor.
  /// It is immutable and equal to the transport passed in the local/resolve
  /// initializer.
  ///
  /// ### Synthesis
  /// Implementation synthesized by the compiler.
  var actorTransport: ActorTransport { get }

  /// Logical address which this distributed actor represents.
  ///
  /// An address is always uniquely pointing at a specific actor instance.
  ///
  /// ### Synthesis
  /// Implementation synthesized by the compiler.
  var actorAddress: ActorAddress { get }

  // === Storage mechanism internals -------------------------------------------

  // FIXME: can we hide this from public API?
  //
  // FIXME: the following; we need the nonisolated conformance
  // main.Person (internal):11:18: error: actor-isolated property 'storage' cannot be used to satisfy a protocol requirement
  //    internal var storage: DistributedActorStorage<String>
  //                 ^
  @actorIndependent(unsafe) // FIXME: pretty nasty... on the local case this breaks isolation then
  // NOT @_distributedActorIndependent on purpose, as it makes it not accessible
  // from outside of the actor, which is good - it is effectively the
  var storage: DistributedActorStorage<DistributedActorLocalStorage> { get set }

  /// ### Synthesis
  /// Implementation synthesized by the compiler.
  // FIXME: can we hide this method from public API?
  static func _mapStorage<T>(keyPath: AnyKeyPath) -> KeyPath<DistributedActorLocalStorage, T>

}

// ==== Codable conformance ----------------------------------------------------

extension CodingUserInfoKey {
  static let actorTransportKey = CodingUserInfoKey(rawValue: "$dist_act_trans")!
}

extension DistributedActor {

  public init(from decoder: Decoder) throws {
    guard let transport = decoder.userInfo[.actorTransportKey] as? ActorTransport else {
      throw DistributedActorCodingError(message: "ActorTransport not available under the decoder.userInfo")
    }

    let container = try decoder.singleValueContainer()
    let address = try container.decode(ActorAddress.self)
    try self.init(resolve: address, using: transport)
  }

  @actorIndependent
  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(self.actorAddress)
  }
}

/******************************************************************************/
/***************************** Actor Transport ********************************/
/******************************************************************************/

public protocol ActorTransport: ConcurrentValue {
  /// Resolve a local or remote actor address to a real actor instance, or throw if unable to.
  /// The returned value is either a local actor or proxy to a remote actor.
  func resolve<Act>(address: ActorAddress, as actorType: Act.Type)
    throws -> ActorResolved<Act> where Act: DistributedActor

  /// Create an `ActorAddress` for the passed actor type.
  ///
  /// This function is invoked by an distributed actor during its initialization,
  /// and the returned address value is stored along with it for the time of its
  /// lifetime.
  ///
  /// The address MUST uniquely identify the actor, and allow resolving it.
  /// E.g. if an actor is created under address `addr1` then immediately invoking
  /// `transport.resolve(address: addr1, as: Greeter.self)` MUST return a reference
  /// to the same actor.
  func assignAddress<Act>(
    _ actorType: Act.Type
//    ,
//    onActorCreated: (Act) -> ()
  ) -> ActorAddress
    where Act: DistributedActor

  // FIXME: call from deinit, or rather the actor destroy
//  func resignAddress(address: ActorAddress)
//    from recipient: ActorAddress
//  ) async throws where Request: Codable, Reply: Codable
}

public enum ActorResolved<Act: DistributedActor> {
  case resolved(Act)
  case makeProxy
}

/******************************************************************************/
/*************************** Actor Personality ********************************/
/******************************************************************************/

// Personality of distributed actors it means either a 'remote' or 'local'
// instance of a distributed actor. It is the same actor type, but playing
// a different role: either a real instance, or a proxy type.

/// A distributed actor's persona represents whether it is a remote proxy
/// or local instance. The 'local' case contains all the actual state of
/// the `distributed actor` as it was declared, while the properties on the
/// outside of the instance are synthesized with replacement accessors
/// reaching "into" the instance, or failing to do so.
///
/// E.g. non distributed properties and functions on a distributed actors will crash the program
/// when attempted to be read from an actor with a remote persona.
public enum DistributedActorStorage<Storage> {
  /// In the remote case, the actor has no actual state,
  /// it is an empty shell which is used only to send messages through.
  case remote
  /// In the local case, all of the actors stored properties are stored in
  /// the synthesized `Storage` value type. Modifications of of `self.property`
  /// are actually forwarded by "proxy" property wrappers to modify the storage.
  indirect case local(Storage)
}

// TODO: make it _DistributedActorValue
@propertyWrapper
public struct DistributedActorValue<Value> {

  @available(*, unavailable, message: "only useful on distributed actors")
  public var wrappedValue: Value {
    get { fatalError("wrappedValue on 'distributed actor' value must never be accessed directly.") }
    set { fatalError("wrappedValue on 'distributed actor' value must never be accessed directly.") }
  }
  
  public static subscript<Myself: DistributedActor>(
    _enclosingInstance actor: /*isolated*/ Myself,
    wrapped wrappedKeyPath: ReferenceWritableKeyPath<Myself, Value>,
    storage storageKeyPath: ReferenceWritableKeyPath<Myself, Self>
  ) -> Value {
    get {
      guard case .local(let DistributedActorLocalStorage) = actor.storage else {
        fatalError("Unexpected access to property of *remote* distributed actor instance \(Myself.self)")
      }

      let kp: KeyPath<Myself.DistributedActorLocalStorage, Value> =
        Myself._mapStorage(keyPath: wrappedKeyPath)
      return DistributedActorLocalStorage[keyPath: kp]
    }
    
    set {
      guard case .local(var DistributedActorLocalStorage) = actor.storage else {
        fatalError("Unexpected access to property of *remote* distributed actor instance \(Myself.self)")
      }
      let kp: WritableKeyPath<Myself.DistributedActorLocalStorage, Value> =
        Myself._mapStorage(keyPath: wrappedKeyPath) as! WritableKeyPath
      DistributedActorLocalStorage[keyPath: kp] = newValue
    }
  }

  public init() {}
}


/******************************************************************************/
/***************************** Actor Address **********************************/
/******************************************************************************/

public struct ActorAddress: Codable, ConcurrentValue, Equatable {
  /// Uniquely specifies the actor transport and the protocol used by it.
  ///
  /// E.g. "xpc", "specific-clustering-protocol" etc.
  public var `protocol`: String

  public var host: String?
  public var port: Int?
  public var nodeID: UInt64?
  public var path: String?

  /// Unique Identifier of this actor.
  public var uid: UInt64 // TODO: should we remove this

  public init(parse: String) {
    self.protocol = "xxx"
    self.host = "xxx"
    self.port = 7337
    self.nodeID = 11
    self.path = "/example"
    self.uid = 123123
  }
}

/******************************************************************************/
/******************************** Misc ****************************************/
/******************************************************************************/

//@_transparent
//public // COMPILER_INTRINSIC
//func _diagnoseUnexpectedDistributedRemoteActor(
//  _filenameStart: Builtin.RawPointer,
//  _filenameLength: Builtin.Word,
//  _filenameIsASCII: Builtin.Int1,
//  _line: Builtin.Word,
//  _isImplicitUnwrap: Builtin.Int1) { // FIXME: remove _isImplicitUnwrap
//  // Cannot use _preconditionFailure as the file and line info would not be printed.
//    _preconditionFailure(
//      "Unexpectedly attempted to access a distributed *remote* actor's state.",
//      file: StaticString(_start: _filenameStart,
//        utf8CodeUnitCount: _filenameLength,
//        isASCII: _filenameIsASCII),
//      line: UInt(_line))
//}

/******************************************************************************/
/******************************* Errors ***************************************/
/******************************************************************************/

/// Error protocol to which errors thrown by any `ActorTransport` should conform.
public protocol ActorTransportError: Error {}

public struct DistributedActorCodingError: ActorTransportError {
  public let message: String

  public init(message: String) {
    self.message = message
  }

  public static func missingTransportUserInfo<Act>(_ actorType: Act.Type) -> Self
    where Act: DistributedActor {
    .init(message: "Missing ActorTransport userInfo while decoding")
  }
}

/******************************************************************************/
/************************* Runtime Functions **********************************/
/******************************************************************************/

// ==== isRemote / isLocal -----------------------------------------------------

@_silgen_name("swift_distributed_actor_is_remote")
public func __isRemoteActor(_ actor: AnyObject) -> Bool

public func __isLocalActor(_ actor: AnyObject) -> Bool {
  return !__isRemoteActor(actor)
}

// ==== Proxy Actor lifecycle --------------------------------------------------

/// Called to create a proxy instance.
@_silgen_name("swift_distributedActor_createProxy")
public func _createDistributedActorProxy<Act>(_ actorType: Act.Type) -> Act // TODO: doug, does the return value "cheat" seem ok?
  where Act: DistributedActor

/// Called to initialize the distributed-remote actor 'proxy' instance in an actor.
/// The implementation will call this within the actor's initializer.
@_silgen_name("swift_distributedActor_remote_initialize")
public func _distributedActorRemoteInitialize(_ actor: AnyObject)


/// Called to destroy the default actor instance in an actor.
/// The implementation will call this within the actor's deinit.
///
/// This will call `actorTransport.resignAddress(self.actorAddress)`.
@_silgen_name("swift_distributedActor_destroy")
public func _distributedActorDestroy(_ actor: AnyObject)
