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

# Distributed in Embedded Swift

Embedded Swift has constraints that make the standard distributed runtime unusable as-is:

- No `Codable` (and no `Encoder`/`Decoder`/`CodingUserInfoKey`). The whole serialization story has to use a different protocol.
- No runtime demangler. `swift_getTypeByMangledNode` / `swift_func_getParameterTypeInfo` and friends do not exist.
- No global accessible-function table. `swift_findAccessibleFunction` does not exist.
- IRGen requires every generic parameter to be class-bound. A generic method `func foo<T: SomeProtocol>(...)` where `SomeProtocol` is not class-bound cannot be emitted.

These constraints rule out the standard `DistributedActorSystem` protocol shape, where `remoteCall<Act, Err, Res>`, `recordArgument<Value>`, `decodeNextArgument<Argument>`, and `onReturn<Success>` are all generic over a `SerializationRequirement` that's usually `Codable` (a value-type protocol, not class-bound).

Under Embedded, distributed actors instead use a **parallel protocol family** that's free of those generics, plus per-type non-generic overloads provided by the user. Most of the rest of the distributed actor machinery (the `distributed actor` keyword, `distributed func` synthesis, `is-remote` check, `Greeter.resolve(id:using:)`) is reused as-is, with small compiler branches where the standard family doesn't fit.

## The protocol family

Defined in `stdlib/public/Distributed/EmbeddedDistributedActorSystem.swift`, gated behind `#if $Embedded`:

```swift
public protocol EmbeddedDistributedActorSystem: Sendable {
  associatedtype ActorID: Sendable & Hashable
  associatedtype InvocationEncoder: EmbeddedDistributedTargetInvocationEncoder
  associatedtype InvocationDecoder: EmbeddedDistributedTargetInvocationDecoder
  associatedtype ResultHandler: EmbeddedDistributedTargetInvocationResultHandler

  func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
    where Act: DistributedActor, Act.ID == ActorID
  func assignID<Act>(_ actorType: Act.Type) -> ActorID
    where Act: DistributedActor, Act.ID == ActorID
  func actorReady<Act>(_ actor: Act)
    where Act: DistributedActor, Act.ID == ActorID
  func resignID(_ id: ActorID)

  func makeInvocationEncoder() -> InvocationEncoder

  // No <Err, Res>. Errors travel as `any Error`. The decoder returned
  // here is later asked for the typed result by the synthesized thunk.
  func remoteCall<Act>(
    on actor: Act, target: RemoteCallTarget, invocation: inout InvocationEncoder
  ) async throws -> InvocationDecoder
    where Act: DistributedActor, Act.ID == ActorID

  func remoteCallVoid<Act>(
    on actor: Act, target: RemoteCallTarget, invocation: inout InvocationEncoder
  ) async throws
    where Act: DistributedActor, Act.ID == ActorID
}

public protocol EmbeddedDistributedTargetInvocationEncoder {
  mutating func doneRecording() throws
  // Per-type recordArgument(_: RemoteCallArgument<T>) and recordReturnType(_: T.Type)
  // overloads are NOT requirements; the user provides them via extensions
  // (see below) for each type that appears in a distributed func signature.
}

public protocol EmbeddedDistributedTargetInvocationDecoder {
  // Per-type decodeNextArgument(_: T.Type) -> T overloads are NOT
  // requirements; provided by extensions on the concrete decoder.
}

public protocol EmbeddedDistributedTargetInvocationResultHandler {
  func onReturnVoid() async throws
  func onThrow(error: any Error) async throws
  // Per-type onReturn(_: T) async throws overloads are NOT requirements;
  // provided by extensions on the concrete handler.
}
```

`DistributedActor` itself is reused. Under `#if $Embedded`, its `associatedtype ActorSystem` is constrained to `EmbeddedDistributedActorSystem` instead of `DistributedActorSystem`, and the `SerializationRequirement` associated type is dropped from the protocol. See the `#if $Embedded` branch in `stdlib/public/Distributed/DistributedActor.swift`.

## Per-type overloads (no generic dispatch)

The serialization-shaped methods are **not** protocol requirements; they're discovered by name lookup against the user's concrete encoder/decoder/handler types. Users add an overload per type they actually use in any `distributed func` signature, typically in an extension:

```swift
struct MyEncoder: EmbeddedDistributedTargetInvocationEncoder {
  mutating func doneRecording() throws { ... }
}

// Add overloads for each type in this project's distributed funcs.
// Extensions can be in any file; the compiler resolves the overload
// against everything in module scope.
extension MyEncoder {
  mutating func recordArgument(_ argument: RemoteCallArgument<String>) throws { ... }
  mutating func recordArgument(_ argument: RemoteCallArgument<Int>)    throws { ... }
  mutating func recordReturnType(_ type: String.Type) throws { ... }
}

extension MyDecoder {
  mutating func decodeNextArgument(_: String.Type) throws -> String { ... }
  mutating func decodeNextArgument(_: Int.Type)    throws -> Int    { ... }
}

extension MyResultHandler {
  func onReturn(_ value: String) async throws { ... }
}
```

The synthesized distributed thunk emits these as plain method lookups (overload-resolved against the encoder/decoder/handler type at SILGen time). No generic instantiation, no witness-table dispatch, no metadata reconstruction.

## Compiler synthesis under Embedded

`deriveBodyDistributed_thunk` in `lib/Sema/CodeSynthesisDistributedActor.cpp` branches on `isEmbeddedDistributedActorSystem(actor)`. When true, it:

1. Emits `encoder.recordArgument(RemoteCallArgument(label:name:value:))` per parameter — same wrapper struct used by standard distributed, just dispatched against a non-generic per-type overload at the call site.
2. Emits `encoder.recordReturnType(R.self)` for the return type.
3. **Skips** `encoder.recordErrorType(...)` (the embedded encoder protocol has no such method; errors travel as `any Error`).
4. Calls `system.remoteCall(on:target:invocation:)` (or `remoteCallVoid(on:target:invocation:)`) — note no `throwing:` or `returning:` labels.
5. For non-`Void` returns, binds the returned `InvocationDecoder` to a local `__decoder` and emits `try decoder.decodeNextArgument(R.self)` — again, overload-resolved on the user's concrete decoder.

All four are non-generic call sites at the SIL level; the user's extension methods are called directly.

## Coverage diagnostic

`checkEmbeddedDistributedFunctionCoverage` in `lib/Sema/TypeCheckDistributed.cpp` walks each `distributed func`'s parameter types and return type, looks them up via `TypeChecker::lookupMember` on the user's `InvocationEncoder` / `InvocationDecoder` / `ResultHandler` types, and emits an error per missing overload. The note suggests the exact paste-ready signature, e.g.:

```
error: embedded distributed actor system encoder 'MyEncoder' is missing an overload of 'recordArgument' for parameter 'name' of type 'String' in distributed instance method
note: add this overload to 'MyEncoder' (or to an extension of it):
  mutating func recordArgument(_ argument: RemoteCallArgument<String>) throws
```

Diagnostic IDs: `distributed_embedded_missing_record_argument`, `distributed_embedded_missing_decode_next_argument`, `distributed_embedded_missing_record_return_type`, `distributed_embedded_missing_on_return`, plus the note `distributed_embedded_missing_overload_note`. See `include/swift/AST/DiagnosticsSema.def`.

## Receiver-side dispatch: compiler-synthesized `_executeDistributedTarget`

For every `distributed actor` whose `ActorSystem` conforms to `EmbeddedDistributedActorSystem`, the compiler synthesizes an instance method on the actor:

```swift
extension Greeter {
  nonisolated public func _executeDistributedTarget(
    target: RemoteCallTarget,
    invocationDecoder: inout Self.ActorSystem.InvocationDecoder,
    resultHandler: Self.ActorSystem.ResultHandler
  ) async throws { ... }
}
```

The synthesized body is an if-chain over `target.identifier` (UTF-8 byte-compared to each distributed func's mangled-thunk name to avoid pulling in Unicode normalization). For each match it decodes the arguments via the user's per-type `decodeNextArgument(_:)` overloads, calls the local distributed function on `self`, hands the result to the user's `onReturn(_:)` / `onReturnVoid()` overload, and forwards thrown errors to `resultHandler.onThrow(error:)`. If no target matches, the method throws `EmbeddedDistributedTargetNotFound`.

The user does not write any of this. From the actor system's receive code:

```swift
func remoteCall<Act>(
  on actor: Act,
  target: RemoteCallTarget,
  invocation: inout InvocationEncoder
) async throws -> InvocationDecoder
    where Act: DistributedActor, Act.ID == ActorID {
  // 1. Ship `invocation`'s bytes off, or here, look up the local actor:
  guard let local = self.locallyRegisteredGreeter else { ... }

  // 2. Dispatch the incoming call to the right local method:
  var decoder = MyDecoder(...)
  let handler = MyResultHandler(...)
  try await local._executeDistributedTarget(
      target: target,
      invocationDecoder: &decoder,
      resultHandler: handler)

  return decoder // populated by the handler with the result
}
```

The synthesis lives in `lib/Sema/CodeSynthesisDistributedActor.cpp` (`synthesizeEmbeddedDistributedReceiveDispatch`, `createEmbeddedDistributedReceiveDispatch`, `deriveBodyEmbeddedDistributedReceiveDispatch`, `buildEmbeddedDispatchBranch`). It runs from `checkDistributedActor` in `lib/Sema/TypeCheckDistributed.cpp`, alongside the existing per-distributed-func thunk synthesis.

The synthesis is opt-out: it does nothing when the actor's `ActorSystem` does not conform to `EmbeddedDistributedActorSystem`. Non-embedded distributed actors continue to use the runtime-demangler-based `swift_distributed_execute_target` path.

## What's gated where

Standard runtime entry points unavailable in the embedded `Distributed` module:

- `executeDistributedTarget` and its underlying `swift_distributed_execute_target` — gated with `@_unavailableInEmbedded` and `#if !$Embedded` in `DistributedActorSystem.swift`. The receiver-side runtime route through the global accessible-function table and the demangler is unused.
- `LocalTestingDistributedActorSystem` — excluded from the embedded build entirely (uses Codable + locks). Users supply their own concrete system.
- `RemoteCallTarget.description` falls back to the raw mangled-name string in embedded; `_getFunctionFullNameFromMangledName` is unavailable.
- `DistributedRemoteActorReferenceExecutor.enqueue` and the implicit Codable conformance extensions on `DistributedActor` are guarded similarly.
- `DistributedActorSystem`-shaped invocation-decoder generic method lookup (`GetDistributedActorConcreteArgumentDecodingMethodRequest`) returns null under embedded — there is no generic `decodeNextArgument<Arg>()` to find.
- `swift5_acfuncs` section emission (`IRGenModule::emitAccessibleFunctions`) is skipped under embedded.
- `lib/IRGen/GenDistributed.cpp::emitDistributedTargetAccessor` is skipped under embedded — the standard receiver-side accessor would pull in the `DistributedTargetInvocationDecoder.decodeNextArgument` dispatch thunk.
- `lib/SIL/IR/SILFunctionBuilder.cpp` does not set the ad-hoc requirement witness reference on distributed thunks under embedded (the reference is only needed to keep the witness alive for the standard demangling-based receiver path).

Runtime entry points enabled in embedded (`stdlib/public/Concurrency/Actor.cpp`):

- `swift_distributedActor_remote_initialize` — yes, needed for `Greeter.resolve(id:using:)`. The embedded variant uses the full instance size for remote proxy allocation (it doesn't trim by the field-offset vector, because `getFieldOffsets()` requires `getResilientMetadataBounds`, which the embedded runtime doesn't provide). Over-allocates by the user-defined property sizes; a follow-up should plumb a non-resilient-only field-offset path.
- `swift_distributed_actor_is_remote` — yes, restricted to the `DefaultActor` path. Non-default-actor distributed actors are not supported in embedded yet.
- `swift_nonDefaultDistributedActor_initialize` — guarded out under embedded; if the user declares a non-default-actor distributed actor, `swift_distributedActor_remote_initialize` traps.

## End-to-end shape

```
   caller side                        receiver side (in this same process for the test)
   -----------                        ---------------
   try await ref.hello(name: "x")
   │
   ▼
   Greeter.hello.TE thunk
   │
   if __isRemoteActor(self):
     var enc = system.makeInvocationEncoder()
     try enc.recordArgument(                       ────► MyEncoder.recordArgument(_: RemoteCallArgument<String>)
         RemoteCallArgument(label: "name",
                            name: "name",
                            value: name))
     try enc.recordReturnType(String.self)        ────► MyEncoder.recordReturnType(String.Type)
     try enc.doneRecording()
     var dec = try await system.remoteCall(on: self, target: ..., invocation: &enc)
                                                  │
                                                  ▼
                                          MySystem.remoteCall<Greeter>(...)
                                          (the user's concrete impl,
                                           specialized for Greeter, the
                                           specialization is emitted into IR)
                                          - decodes wire bytes (or, in the
                                            test, dispatches to the local
                                            greeter directly)
                                          - returns MyDecoder with the result
                                            stashed inside
     return try dec.decodeNextArgument(String.self) ──► MyDecoder.decodeNextArgument(String.Type)
   else:
     return self.hello(name: name)  // direct local call, no encoder/decoder
```

## Tests

All embedded-distributed tests live under `test/Distributed/Embedded/`:

- `distributed_embedded_basic_irgen.swift` — minimum `distributed actor` compiles to LLVM IR; per-actor function symbols appear; the `__swift5_acfuncs` section does not.
- `distributed_embedded_no_forbidden_symbols.swift` — FileCheck confirms `swift_findAccessibleFunction`, `swift_getTypeByMangledNode`, `swift_func_getParameter*`, `swift_conformsToProtocol*`, `swift_distributed_getWitnessTables`, `swift_distributed_execute_target` do **not** appear in emitted IR.
- `distributed_embedded_thunk_uses_per_type_overloads.swift` — `-emit-sil` test that asserts the synthesized thunk calls the user's specific per-type overload methods, not generic dispatch.
- `distributed_embedded_missing_overloads_diag.swift` — `-verify` test that asserts the coverage diagnostics fire when an overload is missing, including the paste-ready notes.
- `distributed_embedded_roundtrip_exec.swift` — full executable: builds a remote reference via `Greeter.resolve`, calls `hello` on it, takes the remote branch through the encoder/`remoteCall`/decoder, asserts the result flows back.

## Open work (not yet done)

- **`@Resolvable` / `any P` / `some P` parameters under embedded.** Phase 2. Today these are not diagnosed under embedded; they will either need to be banned with a clear "not yet supported" diagnostic, or built on top of the AST-level stub-type substitution work in the `wip-wip-distributed-any-some-param-combined` branch.

- **Non-default-actor distributed actors.** Currently trap at runtime in embedded (the `NonDefaultDistributedActor` machinery is gated out). Either re-enable it under embedded or diagnose at the actor declaration site.

- **Field-offset-trimmed remote allocation.** The embedded variant of `swift_distributedActor_remote_initialize` over-allocates (uses the full instance size). A non-resilient-only field-offset accessor would let it match the non-embedded behavior.

- **Codable on `ActorID`.** The implicit `Codable` conformance synthesis on `DistributedActor` where `Self.ID: Codable` is `#if !$Embedded`-guarded today; users must implement `init(from:)` / `encode(to:)` manually if their `ActorID` needs to serialize on the wire. (For most embedded use cases the wire format is custom anyway, so this is acceptable.)
