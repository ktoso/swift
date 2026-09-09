# Distributed module implementation notes

This document is aimed at developers working in the `Distributed` module, and serves as a design document of the runtime internals. This is not a user guide; please refer to the [TSPL](https://github.com/swiftlang/swift-book/blob/main/TSPL.docc/LanguageGuide) and [DocC documentation](stdlib/stdlib.docc/Distributed-collection.md) for the user-facing Distributed module documentation.

> These are implementation details and are allowed to change without further notice.

## Remote/Local Distributed Actors

A `distributed actor` _instance_ is either "local", meaning actual actor state resides in the same memory space, or a reference to a "remote instance". Casually, we refer to them to as local or remote actors. The actual instance of an object is always local, but a "remote reference" simply does not have state and serves only as a reference to the actual local instance located on some other process.

Instances created by an actor `init` are always local. Instances returned from `MyActor.resolve(id:using:)` _may_ be remote, if the actor system returned `nil` while resolving the actor id.

The runtime sometimes calls local ones "known to be local" actors; because generally a distributed actor in the type system pretends to not know if it is remote or local -- to enforce the concept of location transparency. The same code can execute regardless if the passed instance was remote or not. This is a core idea of distributed actors -- assuming that an actor _might be remote_ makes you write code as if it always was. Then, passing a local instance in local tests is just the unusual happy path, but all programming is done against the remote "worst" case.

### Memory layout: local vs remote

A remote distributed actor reference is just a normal heap object, but the runtime allocates enough memory for runtime necessary fields, such as`id`, `actorSystem`, `unownedExecutor` for it. This means a remote actor reference always has the same size in memory, regardless how large of a storage an actual local instance might need. User-declared stored properties are never backed by memory on a remote ref. Safety of this model is enforced by the type-system. It is not possible to refer to any local fields unless the actor is _guaranteed_ to be a local instance.

The allocation is done by `swift_distributedActor_remote_initialize`, and can be thought of like this:

```swift
distributed actor Worker {
  // synthesized:        let id: ActorID
  // synthesized:        let actorSystem: System
  // synthesized:        var unownedExecutor: UnownedSerialExecutor

  var counter: Int = 0  // user-declared stored property
  var name: String = "" // user-declared stored property
}
```

```
   LOCAL instance                       REMOTE instance ("reference to remote actor")

   ┌──────────────────────────┐         ┌──────────────────────────┐
   │ HeapObject header        │         │ HeapObject header        │
   ├──────────────────────────┤         ├──────────────────────────┤
   │ id:           ActorID    │         │ id:           ActorID    │
   │ actorSystem:  System     │         │ actorSystem:  System     │
   ├──────────────────────────┤         ├──────────────────────────┤
   │ unownedExecutor: ...     │         │ unownedExecutor: ...     │
   ├──────────────────────────┤         └──────────────────────────┘
   │ counter:      Int        │          ^^ allocation ends here ^^
   │ name:         String     │          
   └──────────────────────────┘          
```

The runtime may check if an actor is remote, as there is an "is remote" flag set on every distributed actor. This can be checked ar runtime using `__isRemoteActor` / `__isLocalActor`. The user facing API for getting a reference to a local actor–if it indeed was local–is  `actor.whenLocal { isolated actor in ...}`.

## Distributed func calls on remote actors

Any call on a `distributed func` or `distributed var` effectively is redirected to the "distributed thunk" which performs an "if remote, make a remote call" check, like this:

```swift
distributed actor Worker {
  // user-declared method
  distributed func callMe() -> String {
    return "Hello!"
  }
}
```

The synthesized thunk would be as follows:

```swift
extension Worker {
  // synthesized "distributed thunk" -- 'TE' mangling suffix.
  func callMe() async throws -> String {
    if _isDistributedRemoteActor(self) {
      // REMOTE: encode the invocation and pass to remoteCall()
      var invocation = self.actorSystem.makeInvocationEncoder()
      try invocation.recordReturnType(String.self)
      // optional try inv.recordErrorType((any Error).self)
      try invocation.doneRecording()
      let target = RemoteCallTarget("$s...callMe...TE") // mangled name
      return try await self.actorSystem.remoteCall(
          on: self,
          target: target,
          invocation: &invocation,
          throwing: Never.self,
          returning: String.self)
    } else {
      // LOCAL: just call the user-declared body
      return try await self.callMe()
    }
  }
}
```

### Thunks used by Distributed

There is a number of thunks involved in making distributed (remote) calls on distributed actors. Some are on the caller (sender) side, and some on the receiver (recipient) side.

The term "distributed thunk" generally refers specifically to the `...TE` thunk that handles the "if remote, make remote call, otherwise call local method" routing of calls on `distributed func/var`, however the term may be used loosely so it's good to remember all the thunks involved in distributed dispatch:

| Kind | Mangling | Side or purpose | When emitted | Role |
|---|---|---|---|---|
| **distributed thunk** | `...TE` | Caller side; invoke `remoteCall()` when the actor referenced is remote | always (for every distributed target) | "if remote, encode and `system.remoteCall(...)`; else `try await self.<orig>(...)`". This is what user code, witness tables, and protocol dispatch resolve to when calling a `distributed` member. |
| **distributed-target accessor** | `...TETF` | Recipient side; one per `distributed func`/`var`; IR-only (built by `IRGenModule::emitDistributedTargetAccessor`, no SIL) | always paired with a regular distributed thunk | Exposed to the runtime via `forDistributedTargetAccessor` / accessible-function record. Decodes wire arguments via the system's `decodeNextArgument`, then calls a SIL function (the regular thunk by default, or the resolvable-proxy-adapter thunk when one exists). |
| **distributed-thunk witness** | `...TWTE` | Caller side; per protocol-conformance witness for a `distributed func` requirement | always (one per witness) | Forwards from the protocol-witness signature to the implementation's distributed thunk. |
| **resolvable proxy adapter thunk** | `$distributedProxyAdapter$<base>` (plain old function) | Recipient side; synthesized in AST | only when the target has at least one `any P` / `some P` parameter or result for a `@Resolvable protocol` `P` | Bridges between the wire-level proxy stub `$P` and the user-declared `any P` / `some P`. Body forwards to the user func; for `any P` results, re-wraps via `$P.resolve(id: __result.id, using: self.actorSystem)`. |

Wire identity vs. dispatch: the accessor's *symbol* (the one a remote peer's `remoteCall` looks up by mangled name) is always the regular distributed thunk's identity. Whether the accessor body internally calls the regular thunk or the resolvable-proxy-adapter thunk is decided in `IRGenModule::emitDistributedTargetAccessor` and passed through as `dispatchTo`; it is invisible to peers and does not affect the accessor record.

#### "Regular" distributed thunk

**Mangling:** `...TE` on the user-declared `distributed func` / computed-property accessor's mangled name.

**Synthesis:** AST, this is a plain old Swift function which just needs to perform an if/else on the remoteness of the actor.

```swift
nonisolated @concurrent
func compute(_ x: Int) async throws -> String {
  if _isDistributedRemoteActor(self) {
    // REMOTE branch
    var inv = self.actorSystem.makeInvocationEncoder()
    try inv.recordArgument(RemoteCallArgument<Int>(label: nil,
                                                   name: "x",
                                                   value: x))
    try inv.recordReturnType(String.self)
    try inv.recordErrorType((any Error).self)
    try inv.doneRecording()
    let target = RemoteCallTarget("$s4main6WorkerC7computeySSSiYaKFTE")
    return try await self.actorSystem.remoteCall(
        on: self,
        target: target,
        invocation: &inv,
        throwing: (any Error).self,
        returning: String.self)
  } else {
    // LOCAL branch
    return try await self.compute(x) // call the "real" function
  }
}
```

#### Distributed-target accessor

**Mangling:** `...TETF` (the regular thunk's name + `TF`).

**Synthesis:** IR, this accessor is synthesized and emitted in raw IR and is referenced from an `AccessibleFunctionRecord` identified by its mangling. This is what the `executeDistributedTarget` user-facing function locates and invokes when incoming calls are handled. It must obtain and decode values to make the invocation and prepare right generic values to form a correct invocation of the target function.

In pseudo-Swift, it would look something like this:

```swift
// __accessor__<D: DistributedTargetInvocationDecoder>(
//   inout D,                       // decoder
//   UnsafeRawPointer,              // argumentTypes
//   UnsafeRawPointer,              // resultBuffer
//   UnsafeRawPointer?,             // generic substitutions
//   UnsafeRawPointer?,             // witness tables
//   UInt,                          // num witness tables
//   <actor>                        // self
// ) async throws
{
  // Validate decoder argument counts etc.
  // ... 
  
  // For each parameter slot i in the SIL signature of the dispatch target:
  for i in 0 ..< paramCount {
    var argTy = argumentTypes[i]                             // runtime metadata
    // For an `any (@Resolvable P)` / `some (@Resolvable P)` parameter, 
    // override with `$P`'s metadata so `decodeNextArgument` deserializes a `$P` 
    // instead of an `any P`, because:
    // - `any P` cannot conform to e.g. Codable
    // - even if we ferried the underlying type of `PImpl` the recipient may not have 
    //   this type in-process, so the proxy type is decoded instead -- which allows remote calls, but nothing else.
    if originalParam[i] is `any/some @Resolvable P` { 
      argTy = $P.self 
    }
    let value = try decoder.decodeNextArgument<argTy>() // pseudo: argTy is runtime metadata
    arguments.append(value)
  }
  let dispatchTo: TargetFn = 
    if <any @Resolvable subsitutions necessary> {
      resolvable-proxy-adapter // special"adapter" path
    } else {
      target-distributed-thunk // "normal" path
    }
  let result = try await dispatchTo(actorSelf, arguments...)
  resultBuffer.initialize(to: result)
}
```

#### Resolvable proxy adapter thunk

**Mangling:** No special mangling, but a special name prefix: `$distributedProxyAdapter$<base>` as the method is synthesized in Sema/AST.

**Synthesis:** AST, `lib/Sema/CodeSynthesisDistributedActor.cpp`. `createDistributedResolvableProxyAdapterThunkDecl()` builds the `FuncDecl`, `deriveBodyDistributed_resolvableProxyAdapterThunk()` synthesizes its body. Triggered lazily through `GetDistributedRecipientResolvableProxyAdapterThunkRequest`, which only returns a non-null thunk when the target has at least one `@Resolvable` `any P` / `some P` parameter or result. SILGen emits it via `SILGenModule::emitDistributedResolvableProxyAdapterThunkForDecl`.

**Body shape**, in pure Swift, for a method whose parameter and result are both `@Resolvable` existentials:

```swift
distributed func echoActor(
  _ g: any Greeter           // parameter needs $Greeter substitution
) async throws -> any Greeter // result needs $Greeter substitution
```

The synthesized thunk would be:

```swift
func $distributedProxyAdapter$echoActor(
    _ g: $Greeter
) async throws -> $Greeter {
  // === Parameter case
  // $Greeter naturally can be passed to any/some Greeter parameters ($Greeter conforms to Greeter):
  let __result = try await self.echoActor(g)  // typed as the user's return type (any Greeter)
  
  // === Result case
  // The recipient may not have the specific greeter type in-process,
  // so we re-resolve it as the process-boundary friendly proxy type:
  return try $Greeter.resolve(id: __result.id, using: self.actorSystem)
}
```

For computed properties the logic is effectively the same.

#### Distributed-thunk witness (`TWTE`)

**Mangling:** `...TWTE`. Standard protocol-witness thunk mangling (`TW`) plus the distributed-thunk suffix (`TE`).

**Synthesis:** SILGen, via the standard witness-thunk path. When SILGen emits the protocol-conformance witness table for a `@Resolvable` protocol's `distributed func` requirement, it generates a thunk whose body just `function_ref`s the implementation's regular distributed thunk. The `TWTE` form exists because the witness's caller can't know whether the underlying type is local or remote, so the call must always go through the distributed thunk's "if remote" check rather than the original implementation directly.

**Body shape**, in pseudo-SIL (real SIL has `try_apply` + error continuation blocks, elided here):

```sil
sil private [transparent] [distributed_thunk]
    @$s4main8$GreeterCAA0B0A2aDP07sendAnyB0ySSAaD_pYaKFTWTE :
    $@convention(witness_method: Greeter) @async
    (@guaranteed any Greeter, @guaranteed $Greeter)
    -> (@owned String, @error any Error) {
bb0(%g : $any Greeter, %self : $$Greeter):
  %thunk = function_ref @$s4main8$GreeterC07sendAnyB0ySSAA0B0_pYaKFTE  // ...TE on $Greeter
  // try_apply %thunk(%g, %self) : ...
  //   normal bb_ok(%result), error bb_err(%err)
  return %result
}
```

### Implementation: the regular distributed thunk

This diagram explains the flow of a remoteCall made on a concrete distributed actor, like this one:

```swift
distributed actor Worker where ActorSystem == SomeSystem {
  distributed func compute(_ x: Int) async throws -> String { ... }
}
```

```
    try await actor.compute(42) 
                       │
                       ▼
           ┌────────────────────────────────────────────┐
           │ regular distributed thunk                  │
           │ mangling: Worker.compute(_:)...TE          │
           │                                            │
           │  if _isDistributedRemoteActor(self):       │
           │     // REMOTE branch (this runs on caller) │
           │     var inv = system.makeInvocationEncoder │
           │     try inv.recordArgument(                │
           │       RemoteCallArgument<Int>(             │
           │         label, name, x))                   │
           │     try inv.recordReturnType(String.self)  │
           │     try inv.recordErrorType(...)           │
           │     try inv.doneRecording()                │
           │     return try await system.remoteCall(... │
           │                       returning: String.s) │
           │  else:                                     │
           │     // LOCAL branch                        │
           │     return try await self.compute(x)       │  ← original distributed func
           └────────────────────────────────────────────┘
                       │
                       │  Specific ActorSystem's remoteCall does the serialization/networking
                       ▼
        ~~~~~~ process boundary ~~~~~~~~~~~~~~~~~~~~~~~~~~
        
         try await executeDistributedTarget(on: actor, target: target, ...)
                       │
                       ▼
           ┌─────────────────────────────────────────────┐
           │ distributed target accessor (...TETF)       │
           │                                             │
           │   for each param:                           │
           │     decoder.decodeNextArgument<Int>()       │
           │   call the dispatch SIL function (...)      │ ! `dispatchTo` is null here;
           │                                             │    calls the regular thunk
           └─────────────────────────────────────────────┘
                       │
                       │ calls regular distributed thunk
                       │ (will usually hit LOCAL branch, since target is likely local)
                       ▼
           ┌────────────────────────────────────────────┐
           │ user-declared distributed func             │
           │ Worker.compute(_:) async throws -> String  │
           │   { ... }                                  │
           └────────────────────────────────────────────┘
```

Two thunks total: the regular distributed thunk and its accessor. The accessor's `dispatchTo` is null in this case, so it calls the regular distributed thunk directly, which falls into its LOCAL branch (because the recipient holds the actual local actor).

## Distributed calls with `any/some P` where `P` is `@Resolvable protocol`

Resolvable protocols are special in the sense that they allow a remote peer to refer to an actor on another host without knowing its _actual_ type.

For example, a **server** may be hosting:

```swift
distributed actor PolishImpl: Greeter {
   distributed func greet() -> String { "Cześć!" }
}
```

and the only shared information between server and client is the protocol:

```swift
@Resolvable
protocol Greeter: DistributedActor where ActorSystem == SomeSystem {
   distributed func greet() -> String 
}
```

This allows the client side to resolve a "proxy" (or sometimes called "stub") remote reference, by using the synthesized `$Greeter` type:

```swift
let remoteRef: any Greeter = try $Greeter.resolve(<id>, using: system)
```

Next, we want to be able to share these references across remote calls, like this:

```swift
distributed actor CallCenter {
  distributed func callMeLater(_ who: any Greeter)
}
```

This allows us to implement distributed "callbacks", because we can send a remote peer a reference to an actor that they should invoke at a later point in time. This is a fundamental building block for all kinds of bi-directional communication.

> Note: Of course, there must be some validation if we allow given type to be serialized and cross network boundaries, however these checks are up to the system implementation (in `resolve` and in the transport layer), and not up to the language layer which only enforces static concepts.

Here, we want to allow callers to pass _any_ distributed actor that conforms to the `Greeter` protocol.

Without special treatment, this is not supported, because the `any Greeter` existential cannot itself conform to e.g. the `Codable` serialization requirement of a system.

We could also try to send a generic actor, which is technically supported, as long as the system transports the generic type, and vets it against an allow list etc:

```swift
distributed actor CallCenter {
  distributed func callMeLater(_ who: some Greeter)
}
```

Technically this is possible, and the system would just encode the `PolishImpl` type and send it to the remote side.

This hits a problem though: the remote side does not know, nor do we want it to know, about the `PolishImpl` type! Therefore trying to receive `PolishImpl` type, on a system which does not have it, would fail because we cannot create the actor.

Distributed actors are never _actually_ serialized to begin with. We always serialize their ID, and as long as we can transfer that, we can transfer a "remote reference".

We also know that both server and client share the same `protocol Greeter`, and that they use the same actor system. Therefore the availability of the `ActorID` type is guaranteed, as is the availability of the `$Greeter` proxy.

**The solution** is to encode any attempts to "send" an `any/some P` (where the `P` is a `@Resolvable protocol`) as-if we were encoding the `$P`. The recipient side shall then also decode it as-if we were receiving a `$P`, and this way we never attempt to decode unknown distributed actor types on the recipient.

### Implementation: Proxy $P type substitution

For a `distributed func` (or computed `distributed var`) that uses `@Resolvable` `any P` / `some P` in its parameters or result, the process of forming and receiving a call is slightly more involved:

- the distributed thunk (`...TE`) performs a substitution in the generated remote branch code:

```
   try await proxy.sendAnyGreeter(local)        // proxy: GreeterImpl
                       │
                       ▼
           ┌─────────────────────────────────────────────┐
           │ regular distributed thunk                   │
           │                                             │
           │  if _isDistributedRemoteActor(self):        │
           │     // REMOTE branch                        │
           │     var inv = system.makeInvocationEncoder  │
           │     try inv.recordArgument(                 │
           │       RemoteCallArgument<$Greeter>(         │ ! param is encoded as $Greeter
           │         label, name,                        │   using substitution done in AST
           │         try $Greeter.resolve(               │   in deriveBodyDistributed_thunk
           │           id: g.id, using: system)))        │
           │     ...                                     │
           │     return try await system.remoteCall(...) │
           │  else:                                      │
           │     // LOCAL branch                         │
           │     return try await self.sendAnyGreeter(g) │
           └─────────────────────────────────────────────┘
                       │ // remoteCall(...)
                       ▼
    ~~~~~~ process boundary ~~~~~~~~~~~~~~~~~~~~~~~~~~
```

And the recipient side, after the process boundary, decodes the call:

```
        ~~~~~~ process boundary ~~~~~~~~~~~~~~~~~~~~~~~~~~
         try await executeDistributedTarget(on: actor, target: target, ...)
                       │
                       ▼
           ┌─────────────────────────────────────────────┐
           │ distributed target accessor                 │
           │                                             │
           │   for each param:                           │
           │     decoder.decodeNextArgument<$Greeter>()  │ ! decoded as $Greeter
           │                                             │ (no knowledge of GreeterImpl on this node)
           │   << call the [ target | or adapter] >>     │ 
           └─────────────────────────────────────────────┘
                       │ 
           ! ADDITIONAL INDIRECTION !
                       │ 
                       │ calls resolvable-proxy-adapter thunk (if present)
                       ▼
           ┌─────────────────────────────────────────────────┐
           │ resolvable proxy adapter thunk                  │
           │ ($distributedProxyAdapter$sendAnyGreeter)       │
           │ // signature: ($Greeter) async throws -> S      │ ! Signature has any/some Greeter 
           │                                                 │   swapped for wire layer '$Greeter'
           │                                                 │ 
           │   try await self.sendAnyGreeter(g)              │ ! $Greeter conforms to Greeter,
           └─────────────────────────────────────────────────┘   
                       │
                       │ calls user-defined 'distributed func'
                       ▼
           ┌──────────────────────────────────────────────────────────┐
           │ GreeterImpl.sendAnyGreeter(_ g: any Greeter) -> String   │
           │   { return try await g.sayHi() }                         │
           └──────────────────────────────────────────────────────────┘
```

Key flow points:

- The regular distributed thunk is what user code calls and is the only thunk emitted when no `@Resolvable` `any/some P` appears in the signature. Its caller-side body already substitutes `$Greeter` for the encoded argument and the `recordReturnType` (in `deriveBodyDistributed_thunk`).
- The accessor's wire identity (the symbol `remoteCall` looks up via `LinkEntity::forDistributedTargetAccessor`) keeps using the regular thunk's identity. Only the SIL function it dispatches to changes, to the resolvable-proxy-adapter thunk when one exists.
- The resolvable-proxy-adapter thunk's signature is `$Greeter` end-to-end, so the accessor decodes `$Greeter` directly from the wire and never has to box it back into `any Greeter` in IR. The existential erasure happens via a normal Swift implicit conversion in the thunk body.
- For a `some P` parameter, the same thunk works: the user func's generic parameter is bound to `$Greeter` for the call, which still satisfies the `Greeter` constraint.
- For an `any P` *result*, the thunk binds the call's result to `let __result` and emits `return try $Greeter.resolve(id: __result.id, using: self.actorSystem)` so a `$Greeter` ends up on the wire.
- For a computed `distributed var foo: any P { get }`, the original distributed func is the synthesized `_distributed_get_foo` accessor; the resolvable-proxy-adapter thunk is created off that accessor and reads via `MemberRefExpr(self, storage)`.

#### Target invocation redirect (IRGen)

The distributed-target accessor's *linking identity* is always the regular distributed thunk's name (`LinkEntity::forDistributedTargetAccessor`).

The SIL function the accessor actually dispatches to is selected by `IRGenModule::emitDistributedTargetAccessor` and passed to `DistributedAccessor` / `AccessorTarget` as `dispatchTo`. When the target has a `@Resolvable` parameter or result, the accessor needs to dispatch through the proxy-adapter thunk; we locate it and pass it as `dispatchTo`. When no adapter is needed, `dispatchTo` is `nil` and the accessor calls the regular distributed thunk directly.

There is one residual IRGen-side fixup: `argumentTypesBuffer` on the recipient is filled by `__getParameterTypeInfo` from demangling the regular distributed thunk's mangled name, which still says `any P` / `some P`. Since `any P` does not conform to `Codable`, `decodeNextArgument` would trap if invoked with that metadata. The accessor therefore overrides the runtime-loaded `argumentTy` with a compile-time reference to `$P`'s metadata before calling `decodeNextArgument` (see the `@Resolvable protocol param: override runtime-loaded metadata` block in `decodeArguments`).

# Distributed in Embedded Swift (experimental)

Distributed is available in Embedded Swift, however Embedded comes with a number of limitations 
that are necessary for Embedded platforms that make the existing non-Embedded runtime not compatible as-is.

Currently Embedded Distributed is experimental, and you can enable like this: 

```
-enable-experimental-feature Embedded -enable-experimental-feature EmbeddedDistributed
```

In Embedded Embedded, distributed actors use the same `DistributedActorSystem` protocol as usual, 
though some of its requirements are slightly modified. It should be possible for most `DistributedActorSystem` 
implementations to conform to the protocol with a single implementation in both embedded and not.

The only difference is the `remoteCall` function which must be implemented differently in Embedded Swift.

Actual `distributed actor` and resolvable protocol implementations are able to be shared 
between embedded and not-embedded builds, 
because the runtime differences are handled at the actor system layer.

### SerializationRequirement on Embedded systems

The `DistributedActorSystem` does not prescribe using any specific serialization mechanism.
Most non-Embedded systems use `Codable` because its ease of use for end-users,
however this protocol is not available in Embedded Swift so you may need to choose a different mechanism in embedded.

Thankfully, it is possible to write an actor system that simply uses a different serialization _mechanism_
while retaining wire-compatibility with even an potentially non-Embedded client by conditionalizing
the `SerializationRequirement`:

```swift
protocol EmbeddedSerializationRequirement { ... }

extension PortableActorSystem { 
  #if $Embedded
  public typealias SerializationRequirement = EmbeddedSerializationRequirement
  #else
  public typealias SerializationRequirement = Codable
}
```

Or you may write an actor system that just utilizes some portable SerializationRequirement
on all platforms instead.

Only the `SerializationRequirement` might potentially be different between platforms, 
if a system was using `Codable` on non-Embedded, 
because `Codable` is not supported on embedded platforms.
This can be handled easily by introducing a new protocol which handles serialization 
in embedded builds, and conforming types to it when necessary.

```
public struct ComplexRequest: Sendable {
  public let id: Int
  public init(id: Int) { self.id = id }
}

#if $Embedded
extension ComplexRequest: EmbeddedFakeRoundtripActorSystem.SerializationRequirement {
  public var serializedByteCount: Int { 8 }
  public func encode(into output: inout OutputSpan<UInt8>) {
    for byte in asciiDigits(id) { output.append(byte) }
  }
  public static func decode(from input: inout Span<UInt8>) throws -> ComplexRequest {
    guard let id = parseInt(drain(&input)[...]) else { throw WireError.badValue }
    return ComplexRequest(id: id)
  }
}
#else // if !$Embedded
extension ComplexRequest: Codable { }
#endif
```

Since Codable is merely the "how" and not the specific details of the serialization, 
as long as both sides of the protocol can serialize/de-serialize the same payloads, 
this difference does not matter 
and the wire protocol can remain stable and compatible between platforms.

Most of the rest of the distributed actor machinery (the `distributed actor` keyword, `distributed func` synthesis, `is-remote` check, `Greeter.resolve(id:using:)`) is reused as-is, with small compiler branches where the embedded shape differs.

Declaring a `distributed actor` or a concrete `DistributedActorSystem` conformance under `-enable-experimental-feature Embedded` without also enabling `EmbeddedDistributed` is diagnosed with `error: distributed actors in Embedded Swift require '-enable-experimental-feature EmbeddedDistributed'`. The feature gates only user-facing code; the embedded `Distributed` module itself is selected by the `Embedded` feature (`#if $Embedded`) and does not require `EmbeddedDistributed` to build.

## Embedded Distributed Swift Limitations

Some distributed actor features are not supported yet under Embedded Swift.

- **Custom executors are not supported yet.** Only the `DefaultActor` path works. A distributed actor with a custom executor (a non-default actor) traps at runtime.
- **`distributed var` is not supported yet.** Computed distributed properties are diagnosed at the actor declaration site (`distributed_embedded_distributed_var_not_supported`). The receive-side dispatch table only collects `distributed func` members, so a remote property read would have no matching branch.

## Receiver-side: compiler-synthesized `_executeDistributedTarget`

In Embedded Swift, Distributed does not use the accessible function records approach because it would
necessitate the use of dynamic runtime metadata for executing the target functions.


Instead, every `distributed actor` synthesizes an `_executeDistributedTarget` instance method on the actor
that performs the method dispatch on `self`:

```swift
extension Greeter {
  nonisolated(nonsending) public func _executeDistributedTarget(
    target: RemoteCallTarget,
    invocationDecoder: inout Self.ActorSystem.InvocationDecoder,
    resultHandler: Self.ActorSystem.ResultHandler
  ) async throws { ... }
}
```

This is wired into the implementation of `DistributedActorSystem/executeDistributedTarget`

## Code-size overhead

Measured on
`arm64-apple-macos14`, `swift-frontend -O -enable-experimental-feature
Embedded -parse-as-library -wmo`, identical 5-file harness (MySystem +
MyEncoder + MyDecoder + MyResultHandler), differing only in the actor
definition and how `main` calls into it. Two measurement passes: the
`.o` numbers come straight from `size -m`; the linked numbers come
from linking each scenario against the embedded runtime
(`-lswift_Concurrency -lswiftDistributed -lswift_ConcurrencyDefaultExecutor
-lswiftEmbeddedPlatformPOSIX -lswiftExclusivitySingleThreaded
-lswiftUnicodeDataTables`) with `-Xlinker -dead_strip`.

### Per-scenario sizes

| Scenario                                       | `.o` total | linked total |
|------------------------------------------------|-----------|--------------|
| baseline (no actor, just MySystem)             | 6520      | 28319        |
| add a regular `actor` with no methods          | 6852      | 29322        |
| make it `distributed`, still no methods        | 6924      | 29626        |
| declare 1 distributed method, never call it    | 7044      | 29746        |
| 1 distributed method, called from main         | 7508      | 30514        |
| 4 distributed methods, all called              | 8084      | 31114        |
| 8 distributed methods, all called              | 8852      | 31914        |

Linked totals sum `__text + __data + __const + __swift_as_*` from
`size -m` on the stripped binary, which is what actually ships. The
linked overhead dominates the `.o` overhead because most of the cost
is in the embedded `_Concurrency` runtime itself (Actor.cpp,
Task.cpp, TaskStatus.cpp, TaskLocal.cpp ~= 17 KB combined) — that
chunk is constant whether you have one distributed actor or eight,
and is mostly there as soon as you use Swift Concurrency at all.

### What each step costs

- **Per-actor framing (~72 B in `.o`, ~304 B linked):** what you pay
  to turn an `actor` into a `distributed actor` with zero distributed
  methods. Mostly extra slots in `__const` for the actor's metadata
  plus a small grow in the default `__deallocating_deinit`.

- **First call site in the program (~344 B in `.o`, ~768 B linked,
  one-time):** the first `try await x.foo()` anywhere in the binary
  drags in `swift_deletedAsyncMethodErrorTu`, the await-resume
  partial, `async_MainTQ0_`, the async function pointer to main's
  continuation, and `__swift_async_ret_functlets`. Amortized across
  all distributed calls — paid once, regardless of how many
  distributed methods exist.

- **Per declared distributed method (~120 B in `.o`, ~8 B linked when
  never called):** the distributed thunk symbol itself. The link-time
  dead-strip is aggressive: `lld -dead_strip` keeps only the metadata
  vtable slot and the async function pointer (~8 B in `__const`/`__data`)
  when no caller ever names the thunk. The remaining 100+ bytes of
  thunk body get stripped.

- **Per called distributed method (~192 B in `.o`, ~200 B linked):**
  observed by linear regression across C_dist1 (1 method called) ->
  D_dist4 (4 methods) -> E_dist8 (8 methods). The linked-binary
  per-method cost converges to **~200 bytes** — `~192` for `.o`
  symbols + a small constant of stub/got overhead per cross-reference
  added when each new thunk has its own async pointer.

Per-method 192 B `.o` breakdown (from `llvm-objdump --syms` + the
`Counter.mN` symbol families in scenarios D and E):

```
  64 B  __text   suspend-resume partial for distributed thunk Counter.mN
  68 B  __text   suspend-resume partial #N for main's call site
   8 B  __text   Counter.mN()                       (the user's body, post-inlining)
   8 B  __data   async function pointer to thunk
   8 B  __const  type-metadata vtable slot
   4 B  __swift_as_entry   async resume marker
   8 B  __swift_as_cont    async continuation marker
  ----
 ~168 B observed + ~24 B alignment slop = 192 B
```

There is **no per-method metadata table** in embedded distributed.
Non-embedded distributed emits a `__swift5_acfuncs` section indexed
by mangled-name lookup at runtime (`swift_findAccessibleFunction`);
embedded drops both the section and the runtime lookup, dispatching
via the user's specialized `DistributedActorSystem.remoteCall<Greeter>`
overload, which the optimizer picks per-actor. (This is what
`distributed_embedded_no_forbidden_symbols.swift` enforces.)

### Compilation-unit attribution

Sanity-check with `swift-codesize` (apple/applejack tap; wraps
`bloaty` + DWARF) over the linked binary built with `-g` and a
dSYM:

```
swift-codesize generate --binary scen.exe --no-build --include-all
```

The C_dist1 linked binary (1 distributed actor, 1 distributed method,
called once) breaks down by compilation unit:

| Source                                             | Bytes | Symbols |
|----------------------------------------------------|-------|---------|
| `stdlib/public/Concurrency/Actor.cpp`              | 5672  | 78      |
| `stdlib/public/Concurrency/Task.cpp`               | 4756  | 66      |
| `stdlib/public/Concurrency/TaskStatus.cpp`         | 4468  | 58      |
| user code (harness.swift + scenC_dist1.swift)      | 2508  | 43      |
| `stdlib/public/Concurrency/TaskLocal.cpp`          | 2188  | 24      |
| `stdlib/public/Concurrency/TaskAlloc.cpp`          | 1124  | 12      |
| `stdlib/public/Concurrency/CooperativeGlobalExecutor.cpp` | 1064 | 8 |
| (smaller TUs)                                      | ~1100 | ~30     |

Inside the 2508 B of user code, the symbols clearly attributable to
the distributed machinery (`Counter.bump`, the distributed thunk and
its suspend partials, MySystem allocation) sum to ~268 B; the rest is
the `main`/`async_Main` skeleton that any embedded async program
needs.

`swift-codesize`'s value here is **source-line attribution and SIL/IR
drill-down** (set up automatically when run through SwiftPM with
Swift 6.4+). For headline byte numbers, `size -m` + `bloaty -d
sections,symbols` gets the same data without the SwiftPM wrapping.

### Heap-per-instance

The same compilation pass at `-Onone` lets us read the constants that
IRGen plugs into `swift_allocObject` (for the local instance) and into
`swift_distributedActor_remote_initialize_embedded` (for the remote
proxy):

| Stored properties                  | Local instance | Remote proxy |
|------------------------------------|----------------|--------------|
| none                               | 128 B          | 128 B (nothing to trim) |
| 3 × `Int` (24 B of user data)      | 152 B          | **128 B**    |
| `SIMD16<Float>` (64 B + alignment) | 192 B          | 128 B        |

The remote-proxy trim is what the embedded variant of
`swift_distributedActor_remote_initialize` does: it allocates only the
header through the last system-managed field (`id`, `actorSystem`,
`DefaultActorStorage`) and leaves the user's stored properties off,
since a remote reference never reads them. IRGen computes the trim
offset and `alignMask` at compile time from `ClassLayout` and passes
them to the runtime, because the minimal embedded `ClassMetadata` (see
`stdlib/public/core/EmbeddedRuntime.swift`) has no field-offset
vector, no `InstanceSize`, and no `InstanceAlignMask` for the runtime
to read. See `lib/IRGen/GenDistributed.cpp::emitDistributedActorInitializeRemote`
and the embedded branch in `stdlib/public/Concurrency/Actor.cpp`.

## Future work & optimizations

- **Performance of the receive-side if/else chain.** The synthesized
  dispatch groups branches by mangled-name length and switches over
  `target.identifier.utf8.count` first; within each length bucket the
  linear `elementsEqual` scan is unchanged. LLVM lowers the outer
  Int-switch to a jump table.

  The microbenchmark in
  `test/Distributed/Embedded/distributed_embedded_dispatch_microbench.swift`
  measures the cost on the development machine at `-O`:

  | Methods (N) | first branch | middle branch | last branch  |
  |-------------|--------------|---------------|--------------|
  |  1          | ~310 ns      | -             | -            |
  |  4          | ~320 ns      | ~680 ns       | ~860 ns      |
  | 16          | ~310 ns      | ~1.9 us       | ~1.4 us      |
  | 64          | ~320 ns      | ~4.7 us       | ~10.7 us     |

  In the benchmark the method-number suffix produces only two length
  buckets (`m0..m9` are length 65; `m10..m63` are length 66), so the
  last-branch case still scans ~54 names for N=64. Real codebases
  with varied method-name lengths will see much smaller buckets.

  Two issues drive the remaining per-branch cost:

  1. `Sequence.elementsEqual` is iterator-based and does **not**
     short-circuit on `count`. Two iterators advance lockstep,
     reading bytes until they differ. For two 65-byte mangled names
     differing only at byte 60 (the method-number byte), the loop
     reads 60 bytes per branch.
  2. The `Tg5` specialization of `elementsEqual` on `String.UTF8View`
     emits per-call `swift_bridgeObjectRelease` on the String
     backing.

  Further optimizations (deferred, none blocking):

  - **(a) Eight-byte hash-first dispatch.** At compile time, slice a
    UInt64 out of bytes 50..58 (or wherever the names diverge) of
    each mangled name. At runtime, load the same 8 bytes from
    `__identifier`, switch on that UInt64 (LLVM lowers a switch over
    a dense range to a jump table). The matched branch confirms with
    a full byte compare to guard against hash collisions. This makes
    dispatch O(1) for the common case, with the byte compare as a
    constant-cost confirmation.
  - **(b) Replace `elementsEqual` with raw memcmp.** Synthesize a
    `__identifier.withUTF8 { buffer in buffer.count == N && memcmp(buffer.baseAddress, ".str.N....", N) == 0 }`
    body. Eliminates the per-branch retain/release and the iterator
    loop; the optimizer can vectorize memcmp aggressively.

    Empirical: a hand-rolled `withUTF8` + `memcmp` dispatch over 10
    distinct 65-byte mangled names, hitting the last branch,
    measured **~23 ns/call**. Compared against the current synthesized
    dispatch's ~2 us for the same shape (interpolated), that's ~85x
    faster - making this the highest-yield option.
  - **(c) Per-actor identifier cache.** Mirror what non-embedded does
    via `ConcurrentReadableHashMap<AccessibleFunctionCacheEntry>` in
    `stdlib/public/runtime/AccessibleFunction.cpp`: cache the
    matched branch index by a quick hash of `target.identifier`.
    First call does the full scan; repeated calls of the same target
    hit the cache. For real workloads (a handful of methods called in
    a loop) this is essentially free per-call. Open design questions:
    - **Where the cache lives.** Per-actor static var (simplest, but
      shared across instances) or per-instance (more memory). The
      non-embedded path uses a single global hashmap; per-type is
      the embedded analog.
    - **Concurrency.** `_executeDistributedTarget` is `nonisolated`,
      so the cache needs atomics. `Synchronization.Atomic<UInt64>`
      is embedded-safe. A single-entry cache (one UInt64 hash + one
      Int idx) tolerates races: a stale read just leads to one extra
      full scan and a re-store; correctness is preserved because the
      full scan always confirms the matched branch (the cached idx
      is consulted only to skip the scan, never to bypass the byte
      compare).
    - **Hash function.** A FNV-1a or splitmix64 over the bytes of
      the identifier is enough for a tiny cache. For a hashmap, use
      the embedded stdlib's `Hasher` (which is available).
    - **Eviction.** Trivial for single-entry (always overwrite).
      For multi-entry, modulo into a small fixed array indexed by
      `hash & 7`.

  (b) requires synthesizing `withUTF8 { ... }` closures around the
  whole dispatch body, which is more involved but where the empirical
  ~85x win lives. (a) and (c) are larger design exercises; (c) in
  particular is what the C++ runtime uses today, and is the cleanest
  long-term answer if multiple distinct target identifiers per actor
  are common.

  None of these are blocking for Phase 2 - the current dispatch works
  correctly. They're optimizations for actors with large numbers of
  distributed methods, picked up after the design is settled.
