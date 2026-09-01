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

Under Embedded, distributed actors use the **same `DistributedActorSystem` protocol family**, defined with an `#if $Embedded` branch that keeps `SerializationRequirement` but binds it to a concrete protocol the *system* supplies (Embedded has no `Codable`), and that reshapes `remoteCall` to return the result `Res` directly (no `<Err>` generic, no `throwing:` / `returning:` metatype parameters). The record/decode/onReturn members stay generic over `SerializationRequirement` - the same single generic ad-hoc methods as non-embedded - and every call site is specialized under WMO because embedded systems are always concrete. There is no separate embedded protocol: the single protocol name compiles to two shapes depending on the `Embedded` feature. This is what makes a `distributed actor` and its actor-system conformance clause source-portable across the two modes; only the serialization layer (the encoder/decoder/handler members and the `remoteCall` signatures) is mode-specific. Most of the rest of the distributed actor machinery (the `distributed actor` keyword, `distributed func` synthesis, `is-remote` check, `Greeter.resolve(id:using:)`) is reused as-is, with small compiler branches where the embedded shape differs.

## The protocol family

The embedded shape lives in **separate files**: `stdlib/public/Distributed/DistributedActorSystem+Embedded.swift` and `stdlib/public/Distributed/DistributedActor+Embedded.swift`. Each is the `#if $Embedded` shape of a protocol whose non-embedded shape stays in the base `stdlib/public/Distributed/DistributedActorSystem.swift` / `DistributedActor.swift`. Only one shape is ever compiled per build. The embedded shape matches the non-embedded one everywhere except the serialization-shaped members. Under `#if $Embedded`, `DistributedActorSystem` is:

```swift
public protocol DistributedActorSystem: Sendable {
  associatedtype ActorID: Sendable & Hashable

  // Kept, exactly like non-embedded. The concrete system binds this to its
  // own protocol; Embedded cannot use Codable
  associatedtype SerializationRequirement

  associatedtype InvocationEncoder: DistributedTargetInvocationEncoder
  associatedtype InvocationDecoder: DistributedTargetInvocationDecoder
  associatedtype ResultHandler: DistributedTargetInvocationResultHandler

  func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
    where Act: DistributedActor, Act.ID == ActorID
  func assignID<Act>(_ actorType: Act.Type) -> ActorID
    where Act: DistributedActor, Act.ID == ActorID
  func actorReady<Act>(_ actor: Act)
    where Act: DistributedActor, Act.ID == ActorID
  func resignID(_ id: ActorID)

  func makeInvocationEncoder() -> InvocationEncoder

  // Returns the decoded result directly. No <Err> generic and no
  // throwing: / returning: metatype parameters. Errors travel as any Error.
  // Res is inferred from the call context; the concrete system decodes the
  // response wire into Res inside this body. Res: SerializationRequirement
  // is enforced by the conformance check, not spelled on the requirement
  func remoteCall<Act, Res>(
    on actor: Act, target: RemoteCallTarget, invocation: inout InvocationEncoder
  ) async throws -> Res
    where Act: DistributedActor, Act.ID == ActorID
          // Res: SerializationRequirement

  func remoteCallVoid<Act>(
    on actor: Act, target: RemoteCallTarget, invocation: inout InvocationEncoder
  ) async throws
    where Act: DistributedActor, Act.ID == ActorID
}

public protocol DistributedTargetInvocationEncoder {
  mutating func doneRecording() throws
  // The single generic recordArgument is ad-hoc (not a formal requirement),
  // provided by the concrete encoder, typically via an extension:
  //
  //   mutating func recordArgument<Value: SerializationRequirement>(
  //     _ argument: RemoteCallArgument<Value>) throws
  //
  // The return type is not recorded under Embedded (it carries no wire metadata)
}

public protocol DistributedTargetInvocationDecoder {
  // The single generic decodeNextArgument is ad-hoc, provided by the concrete
  // decoder. Note: no metatype parameter; the result type is inferred:
  //
  //   mutating func decodeNextArgument<Argument: SerializationRequirement>()
  //     throws -> Argument
}

public protocol DistributedTargetInvocationResultHandler {
  func onReturnVoid() async throws
  func onThrow(error: any Error) async throws
  // The single generic onReturn is ad-hoc, provided by the concrete handler:
  //
  //   func onReturn<Success: SerializationRequirement>(_ value: Success)
  //     async throws
}
```

`DistributedActor` keeps its `associatedtype SerializationRequirement` and the `where SerializationRequirement == ActorSystem.SerializationRequirement` clause, exactly like non-embedded, and its `associatedtype ActorSystem` is constrained to `DistributedActorSystem` in both modes. There is no embedded-only drop of any associated type; the `DistributedActor` shape is identical across modes, which is what makes a `distributed actor` declaration source-portable. See `stdlib/public/Distributed/DistributedActor+Embedded.swift`.

## A single generic serialization method

The serialization-shaped methods are **not** formal protocol requirements; they're discovered by name lookup against the user's concrete encoder/decoder/handler types. Instead of one non-generic overload per type, the user writes a **single generic method** constrained by the system's `SerializationRequirement`, and conforms each type they move to that protocol *once*:

```swift
// The concrete system's own serialization requirement (Embedded has no
// Codable). Adopters conform their argument / return types to this
protocol MySerializationRequirement { ... }
extension String: MySerializationRequirement { ... }
extension Int: MySerializationRequirement { ... }

struct MyEncoder: DistributedTargetInvocationEncoder {
  mutating func doneRecording() throws { ... }
}

// One generic method each, typically in an extension. Extensions can be in
// any file; the compiler resolves the member against everything in module
// scope
extension MyEncoder {
  mutating func recordArgument<Value: MySerializationRequirement>(
      _ argument: RemoteCallArgument<Value>) throws { ... }
}

extension MyDecoder {
  mutating func decodeNextArgument<Argument: MySerializationRequirement>()
      throws -> Argument { ... }
}

extension MyResultHandler {
  func onReturn<Success: MySerializationRequirement>(_ value: Success)
      async throws { ... }
}
```

Embedded normally forbids a generic parameter constrained to a non-class-bound protocol, but only for *runtime witness-table dispatch*. `GenericSignature::canBeEmittedInEmbeddedSwift` allows these signatures, and `WitnessTableBuilder::addMethod` nulls the witness-table slot so the requirement exists but must always be specialized. Because embedded rejects actors generic over their system (`TypeCheckDistributed.cpp`), every system/encoder/decoder/handler at a serialization call site is concrete, so under WMO they all devirtualize and specialize. The synthesized distributed thunk emits these as ordinary member calls that specialize away; no generic instantiation, no witness-table dispatch, no metadata reconstruction survives.

## Compiler synthesis under Embedded

`deriveBodyDistributed_thunk` in `lib/Sema/CodeSynthesisDistributedActor.cpp` branches on whether the enclosing distributed actor is compiled under the Embedded feature (a distributed actor plus `LangOpts.hasFeature(Feature::Embedded)`). When true, it:

1. Emits `encoder.recordArgument(RemoteCallArgument(label:name:value:))` per parameter - same wrapper struct used by standard distributed, calling the single generic `recordArgument<Value: SerializationRequirement>` (specialized at the call site because the argument type is concrete).
2. **Skips** `encoder.recordReturnType(...)` - the return type carries no wire metadata under Embedded; the receiver-side dispatch already knows each target's concrete return type statically from the mangled target name.
3. **Skips** `encoder.recordErrorType(...)` (the embedded encoder protocol has no such method; errors travel as `any Error`).
4. Calls `system.remoteCall(on:target:invocation:)` (or `remoteCallVoid(on:target:invocation:)`) - note no `throwing:` or `returning:` labels. The result type `Res` is inferred from the thunk's return-position contextual type; there is no `returning:` metatype argument as in standard distributed.
5. Returns the value of `remoteCall` directly. Unlike standard distributed, `remoteCall` already returns `Res` (not an `InvocationDecoder`), so the thunk performs no sender-side decode - result decoding lives inside the concrete system's `remoteCall` body. For a `@Resolvable` result the thunk coerces the call to the wire-level `$P` stub (which conforms to `SerializationRequirement`) so `Res` binds to `$P`; the implicit existential erasure at the `return` turns the `$P` back into the `any/some P` the thunk declares.

The real call sites (`recordArgument`, `remoteCall`) are specialized at the SIL level; the user's single generic methods devirtualize into direct concrete calls under WMO.

## Coverage diagnostic

Because the embedded system binds `SerializationRequirement` to a real protocol, argument and return-type coverage is checked the *standard* way: every `distributed func` parameter and result type must conform to the system's `SerializationRequirement`. `getDistributedActorSerializationType` returns that protocol (no longer short-circuiting to `Any` under Embedded), so the ordinary per-parameter check (`distributed_actor_func_param_not_codable`) and result check (`checkDistributedTargetResultType`) fire, naming the system's protocol:

```
error: parameter 'name' of type 'NotSerializable' in distributed instance method
       does not conform to serialization requirement 'MySerializationRequirement'
```

There are no bespoke per-overload diagnostics anymore. `checkEmbeddedDistributedFunctionCoverage` in `lib/Sema/TypeCheckDistributed.cpp` keeps only the *language-feature* rejections that are specific to Embedded: user-written generic `distributed func`s, `some P` parameters/returns, and non-`@Resolvable` `any P` parameters/returns (which have no `$P` wire stub). The old `distributed_embedded_missing_record_argument` / `_decode_next_argument` / `_on_return` / `_missing_overload_note` diagnostics were removed along with the per-type overload design.

## Receiver-side dispatch: compiler-synthesized `_executeDistributedTarget`

For every `distributed actor` in a module compiled under the Embedded feature, the compiler synthesizes an instance method on the actor:

```swift
extension Greeter {
  nonisolated public func _executeDistributedTarget(
    target: RemoteCallTarget,
    invocationDecoder: inout Self.ActorSystem.InvocationDecoder,
    resultHandler: Self.ActorSystem.ResultHandler
  ) async throws { ... }
}
```

The synthesized body is an if-chain over `target.identifier` (UTF-8 byte-compared to each distributed func's mangled-thunk name to avoid pulling in Unicode normalization). For each match it decodes the arguments via the user's single generic `decodeNextArgument<Argument: SerializationRequirement>()` (specialized per concrete argument type), calls the local distributed function on `self`, hands the result to the user's `onReturn<Success: SerializationRequirement>(_:)` / `onReturnVoid()`, and forwards thrown errors to `resultHandler.onThrow(error:)`. If no target matches, the method throws `EmbeddedDistributedTargetNotFound`.

The user does not write any of this. From the actor system's receive code:

```swift
func remoteCall<Act, Res>(
  on actor: Act,
  target: RemoteCallTarget,
  invocation: inout InvocationEncoder
) async throws -> Res
    where Act: DistributedActor, Act.ID == ActorID,
          Res: SerializationRequirement {
  // 1. Ship `invocation`'s bytes off, or here, look up the local actor:
  guard let local = self.locallyRegisteredGreeter else { ... }

  // 2. Dispatch the incoming call to the right local method. The result
  //    handler stashes the return value where this body can read it back:
  var decoder = MyDecoder(...)
  let handler = MyResultHandler(...)
  try await local._executeDistributedTarget(
      target: target,
      invocationDecoder: &decoder,
      resultHandler: handler)

  // 3. Decode the result off the wire and return it as `Res`. The sender
  //    thunk does no decoding of its own - that lives here now.
  return try decoder.decodeNextArgument()
}
```

The synthesis lives in `lib/Sema/CodeSynthesisDistributedActor.cpp` (`synthesizeEmbeddedDistributedReceiveDispatch`, `createEmbeddedDistributedReceiveDispatch`, `deriveBodyEmbeddedDistributedReceiveDispatch`, `buildEmbeddedDispatchBranch`). It is driven from two places, and is idempotent so that both may run:

- Eagerly from `checkDistributedActor` in `lib/Sema/TypeCheckDistributed.cpp`, alongside the existing per-distributed-func thunk synthesis. This is what registers the function with `SF->addDelayedFunction` so SILGen emits it.
- Lazily from `NominalTypeDecl::synthesizeSemanticMembersIfNeeded` (`lib/AST/Decl.cpp`) via `ImplicitMemberAction::ResolveEmbeddedDistributedReceiveDispatch`, so that a *lookup* of `_executeDistributedTarget` triggers the synthesis.

The lazy path matters because the eager pass runs per source file, while the natural caller of `_executeDistributedTarget` is the actor system's `remoteCall`, which normally lives in a different file from the actor. Without it, sema reports "value of type 'Greeter' has no member '_executeDistributedTarget'" whenever the two are not in the same file. This is the same mechanism `CodingKeys` / `Encodable` / `Decodable` use. Covered by `distributed_embedded_multifile_dispatch_exec.swift`.

The synthesis is opt-out: it does nothing outside Embedded mode. Non-embedded distributed actors continue to use the runtime-demangler-based `swift_distributed_execute_target` path.

## What's gated where

Standard runtime entry points unavailable in the embedded `Distributed` module:

- `executeDistributedTarget` and its underlying `swift_distributed_execute_target` — gated with `@_unavailableInEmbedded` and `#if !$Embedded` in `DistributedActorSystem.swift`. The receiver-side runtime route through the global accessible-function table and the demangler is unused.
- `LocalTestingDistributedActorSystem` — excluded from the embedded build entirely (uses Codable + locks). Users supply their own concrete system.
- `RemoteCallTarget.description` falls back to the raw mangled-name string in embedded; `_getFunctionFullNameFromMangledName` is unavailable.
- `DistributedRemoteActorReferenceExecutor.enqueue` and the implicit Codable conformance extensions on `DistributedActor` are guarded similarly.
- `DistributedActorSystem`-shaped invocation-decoder generic method lookup (`GetDistributedActorConcreteArgumentDecodingMethodRequest`) returns null under embedded — its consumers (the runtime-demangler receiver path) are dead in embedded, so the concrete decoding method is never needed there.
- `swift5_acfuncs` section emission (`IRGenModule::emitAccessibleFunctions`) is skipped under embedded.
- `lib/IRGen/GenDistributed.cpp::emitDistributedTargetAccessor` is skipped under embedded — the standard receiver-side accessor would pull in the `DistributedTargetInvocationDecoder.decodeNextArgument` dispatch thunk.
- `lib/SIL/IR/SILFunctionBuilder.cpp` does not set the ad-hoc requirement witness reference on distributed thunks under embedded (the reference is only needed to keep the witness alive for the standard demangling-based receiver path).

Runtime entry points enabled in embedded (`stdlib/public/Concurrency/Actor.cpp`):

- `swift_distributedActor_remote_initialize_embedded` — the embedded-only variant of `swift_distributedActor_remote_initialize`, needed for `Greeter.resolve(id:using:)`. It takes the remote-proxy allocation size and alignment mask precomputed by IRGen from `ClassLayout`, because the minimal embedded `ClassMetadata` carries no field-offset vector, `InstanceSize`, or `InstanceAlignMask` for the runtime to read. See `lib/IRGen/GenDistributed.cpp::emitDistributedActorInitializeRemote` and the trim numbers under "Heap-per-instance" below. The non-embedded `getDistributedRemoteActorAllocSize` path is unused under embedded.
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

     // === Encode arguments
     // Call the single generic 'recordArgument<Value: SerializationRequirement>',
     // specialized here for 'String':
     try enc.recordArgument(
         RemoteCallArgument(label: "name",
                            name: "name",
                            value: name))
     try enc.doneRecording()
     return try await system.remoteCall(on: self, target: ..., invocation: &enc)
                                                  │
                                                  ▼
                                          MySystem.remoteCall<Greeter, String>(...)
                                          (the user's concrete impl,
                                           specialized for Greeter, the
                                           specialization is emitted into IR)
                                          - decodes wire bytes (or, in the
                                            test, dispatches to the local
                                            greeter directly)
                                          - returns the decoded 'String'
                                            result directly (no decoder dance
                                            on the sender side)
   else:
     return self.hello(name: name)  // direct local call, no encoder/decoder
```

## Tests

All embedded-distributed tests live under `test/Distributed/Embedded/`:

- `distributed_embedded_basic_irgen.swift` — minimum `distributed actor` compiles to LLVM IR; per-actor function symbols appear; the `__swift5_acfuncs` section does not. Asserts the specialized `remoteCall<Greeter, ...>` is emitted and no generic `remoteCall` survives.
- `distributed_embedded_no_forbidden_symbols.swift` — FileCheck confirms `swift_findAccessibleFunction`, `swift_getTypeByMangledNode`, `swift_func_getParameter*`, `swift_conformsToProtocol*`, `swift_distributed_getWitnessTables`, `swift_distributed_execute_target` do **not** appear in emitted IR. The canary for the nulled-witness-slot hypothesis: a stray unspecialized generic `remoteCall` would reintroduce witness-table machinery.
- `distributed_embedded_thunk_uses_generic_serialization.swift` — `-emit-sil` test that asserts the synthesized thunk calls the single generic `recordArgument` / `remoteCall` (specialized), and does **not** decode the result on the sender side (no decoder dance).
- `distributed_embedded_arg_result_not_conforming_diag.swift` — `-verify` test that asserts the standard `distributed_actor_func_param_not_codable` (and result-type variant) fires when a parameter/return type does not conform to the system's `SerializationRequirement`.
- `distributed_embedded_partial_conformance_diag.swift` — `-verify` test that a type conforming to the serialization requirement is accepted while a sibling non-conforming type in the same actor is diagnosed.
- `distributed_embedded_generic_actor_system_diag.swift` — `-verify` test that an actor generic over its system is rejected (the precondition that keeps every system concrete under embedded).
- `distributed_embedded_synthesized_dispatch_sil.swift` — `-emit-sil` test pinning the synthesized `_executeDistributedTarget` if-chain over `target.identifier`.
- `distributed_embedded_target_not_found_compiles.swift` — a call to an unknown target compiles; the receiver throws `EmbeddedDistributedTargetNotFound` at runtime.
- `distributed_embedded_multiple_actors.swift` / `distributed_embedded_multiple_funcs.swift` — several distributed actors / several distributed funcs in one module compile and dispatch correctly.
- `distributed_embedded_removed_protocol_names.swift` - `-verify` test asserting the removed parallel protocol names (`EmbeddedDistributedActorSystem`, `EmbeddedDistributedTargetInvocationEncoder`, `EmbeddedDistributedTargetInvocationDecoder`, `EmbeddedDistributedTargetInvocationResultHandler`) are gone: referencing them yields "cannot find type ... in scope".
- `distributed_embedded_source_portability.swift` - one file with two RUN lines (with and without `-enable-experimental-feature Embedded`). The same portable `distributed actor` + actor-system core compiles in both modes; only the serialization layer (encoder/decoder/handler, plus the actor `ID`'s `Codable` conformance) is gated behind `#if $Embedded` / `#else`. Guards against the two protocol families drifting apart.
- `distributed_embedded_any_some_param_diag.swift` — `-verify` test pinning Phase 2 sema: `any P` with `@Resolvable` accepted; `some P` rejected with "use 'any P' instead"; `any P` without `@Resolvable` rejected; user-written generic distributed funcs rejected.

Executable / runtime tests under `Runtime/`:

- `distributed_embedded_roundtrip_exec.swift` — full executable: builds a remote reference via `Greeter.resolve`, calls `hello` on it, takes the remote branch through the encoder / `remoteCall` / decoder, asserts the result flows back. Uses the shared `Inputs/EmbeddedFakeActorSystem.swift` with `encode(into:)` / `decode(from:)` and `remoteCall -> Res`.
- `distributed_embedded_synthesized_dispatch_exec.swift` — executable companion to the SIL dispatch test.
- `distributed_embedded_cross_module_resolvable_exec.swift` — a custom type serialized across module boundaries via the shared fake system's generic serialization.
- `distributed_embedded_dce_keeps_dispatch_exec.swift` — asserts dead-code elimination does not strip the synthesized dispatch when the target is reachable only through `remoteCall`.
- `distributed_embedded_dispatch_microbench.swift` — a minimal in-process system that measures dispatch overhead; converted to the single generic serialization method + `remoteCall -> Res`.
- `distributed_embedded_resolvable_any_roundtrip_exec.swift` — full Phase 2 executable: `Hub.dispatch(to: any RWorker)` invoked with a `$RWorker` proxy, inner `worker.work(name:)` re-enters the stub transport and dispatches to the concrete `WorkerImpl.work`, result flows back. The `$RWorker` stub conforms to the system's `SerializationRequirement`.
- `distributed_embedded_multifile_dispatch_exec.swift` — the actor and the actor system live in separate files (the actor is in `Inputs/multifile_dispatch_actor.swift`), exercised in both file orders. Pins the lazy-synthesis path for `_executeDistributedTarget`; every other test here is single-file.

Note when adding tests here: gate on `swift_feature_Embedded` plus
`optimized_stdlib` / `executable_test` / OS as appropriate. Do **not** write
`// REQUIRES: swift_in_compiler` — that feature is not defined anywhere in the
repository, so it silently marks the test `UNSUPPORTED` forever. Every test in
this directory carried it at one point and none of them ran.

## Code-size overhead

What does opting into `distributed actor` cost in an embedded binary,
relative to plain Swift / a regular `actor`? Measured on
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

## `@Resolvable` `any P` parameters and returns

The compiler accepts `any P` parameters and return types in
`distributed func` signatures under Embedded **iff** `P` is annotated
with `@Resolvable`. The macro emits a peer `distributed actor $P:
P, _DistributedActorStub` whose generated thunks ship over the wire in
place of the `any P` existential, recovering the static-shape property
embedded Swift needs.

What is **not** supported, and why:

- **`some P` parameters.** Even with `@Resolvable`, the user-facing
  body sees a generic archetype; the synthesized thunk would need
  `recordGenericSubstitution(T.self)` on the encoder to communicate
  the concrete type to the receiver. The embedded encoder protocol
  family has no such requirement (it has no runtime-metadata path).
  Diagnosed as `distributed_embedded_some_param_not_supported` with
  fix-it "use 'any P' instead".
- **`any P` without `@Resolvable`.** No `$P` stub type exists for the
  thunk to use as the wire shape. Diagnosed as
  `distributed_embedded_any_some_param_not_supported`.
- **User-written generic `distributed func`s.** Same generic-substitution
  story as `some P`. Diagnosed as
  `distributed_embedded_generic_func_not_supported`. The check
  distinguishes user-written generic params from implicit ones
  introduced by `some P` (uses `GenericTypeParamDecl::isOpaqueType`)
  so the `some P` case gets the more specific diagnostic.

### Wire shape

The sender thunk for `distributed func dispatch(to: any RWorker)` rewrites
the type at every wire-level position:

```
encoder.recordArgument(RemoteCallArgument<$RWorker>(label:"to", name:"worker", value: $worker))
RemoteCallTarget("<mangled name of $RWorker.work's thunk>")
system.remoteCall(on: ..., target: ..., invocation: &enc) -> decoder
return try decoder.decodeNextArgument($RWorker.self)  // for `-> any RWorker` returns
```

The substitution is `getDistributedResolvableProtocolStubType(paramTy)`
in `lib/Sema/CodeSynthesisDistributedActor.cpp`. The
`recordGenericSubstitution` block in `deriveBodyDistributed_thunk` is
skipped entirely under embedded; any generic-env entries that remain
are protocol-extension `Self` parameters from `@Resolvable` extension
thunks and carry no useful wire-level substitution under embedded.

### Receive-side dispatch table (per-actor)

Each embedded distributed actor `T` gets a synthesized
`_executeDistributedTarget(target:invocationDecoder:resultHandler:)`
method (see `synthesizeEmbeddedDistributedReceiveDispatch` and
`buildEmbeddedDispatchBranch` in
`lib/Sema/CodeSynthesisDistributedActor.cpp`). The body is an if/else
chain over `target.identifier.utf8.elementsEqual("<mangled>".utf8)`
calls, one branch per distributed func collected for `T`. 

The collection is:

1. **Every concrete `distributed func` declared on `T`.** Mangled name
   is `T.<method>`'s thunk (e.g.
   `$e<module>10WorkerImplC4work4nameS2S_tYaKFTE`).
2. **Every distributed requirement on every `@Resolvable` protocol
   that `T` conforms to.** Mangled name is the `$P.<method>` thunk
   (e.g. `$e<module>8$RWorkerC4work4nameS2S_tYaKFTE`). This is the
   target identifier the sender thunk produces when the call goes
   through `any P` -> `$P` proxy.

The body of each matched branch decodes args with `$P` substituted
for `any P`, calls `self.<method>(...)`, and hands the result to the
result handler. The `self.<method>(...)` call dynamically dispatches
into the concrete impl regardless of which target identifier matched
(Swift's normal class-method dispatch).

This mirrors what non-embedded mode does at runtime: the
`swift_findAccessibleFunction` registry contains accessors keyed by
mangled name; the accessor for `$P.<method>` dispatches into the
conforming type via witness tables. We can't do that in embedded (no
runtime accessor table, no witness-table-by-mangled-name lookup), so
the same routing is reified at compile time as extra branches in
every conforming actor's synthesized dispatch method.

UTF-8 byte comparison via `elementsEqual` is used (not `String ==`)
because embedded Swift doesn't link the Unicode NFC normalization
helpers; the mangled name is plain ASCII so byte-equal is correct.

### Return path: `any P` -> `$P` for `onReturn`

When the user's body returns `any P`, the result handler's single
generic `onReturn<Success: SerializationRequirement>` is specialized
for `$P` (the `$P` stub conforms to the system's `SerializationRequirement`).
The receive-side dispatch synthesizes a
`$P.resolve(id: __result.id, using: self.actorSystem)` call to turn the
`any P` back into a `$P` proxy before invoking `onReturn`. On the caller
side the sender thunk performs no decode of its own; `remoteCall` returns
`Res` bound to `$P` (the thunk coerces the call to the `$P` stub so `Res`
infers as `$P`), and the implicit `$P: P` existential conversion at the
`return` hands the user back `any P`.

## Open work (not yet done)

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

- **Non-default-actor distributed actors.** Currently trap at runtime in embedded (the `NonDefaultDistributedActor` machinery is gated out). Either re-enable it under embedded or diagnose at the actor declaration site.

- **`distributed var` is not dispatched.** The sender side works: `checkDistributedActor` synthesizes the thunk for a `distributed var` via its `VarDecl` arm. But the receive-side dispatch table does not, because the collection loop in `synthesizeEmbeddedDistributedReceiveDispatch` only walks `dyn_cast<FuncDecl>(member)`, and a `distributed var`'s getter is an `AccessorDecl` nested inside the `VarDecl` rather than a direct member of the actor. The result is no dispatch branch, so reading a `distributed var` on a remote reference throws `EmbeddedDistributedTargetNotFound` at runtime with no compile-time diagnostic. There is no test coverage for `distributed var` in this directory at all.

  To support it: add a `VarDecl` arm to that collection loop keyed on `var->getDistributedThunk()`, emit a branch on the getter thunk's mangled name whose body reads the property and hands the value to `onReturn(_:)` (no arguments to decode, so it is simpler than a method branch), and extend `checkEmbeddedDistributedFunctionCoverage` to cover the getter's return type so a missing overload is a compile-time error rather than a runtime one.
