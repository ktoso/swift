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

## Receive-side call validation: `@Entitlement` and `@ValidateRemoteCall`

> WIP: this section describes machinery that is landing on
> `wip-remote-call-validation`. The paragraphs below track the branch's
> current state; they will be edited into a final shape (and cross-linked
> with the stdlib DocC docs) before the branch is squashed for PR.

Distributed actor systems that expose methods over untrusted transport often need to reject a call before it decodes, based on caller identity or capability. Two attached peer macros express this at the source level:

- `@Entitlement(_ policy: EntitlementPolicy)` — declarative check against a task-local set of granted entitlements. Composes with `.anyOf` / `.allOf` and desugars a bare string literal to `.entitlement(...)`.
- `@ValidateRemoteCall(_ validator: RemoteCallValidator)` — a named reusable validator recipe, or (on concrete methods only) an inline closure. Fires before argument decoding.

Both apply to a `distributed func` or `distributed var` and can also be written on a protocol requirement, in which case the compiler inherits them onto every conforming actor's witness without the user restating anything.

### Runtime shape

Validation is split between the macro and the compiler because neither can emit both halves. The macro can run arbitrary Swift (to build the validator) but cannot see the mangled name or emit a pointer in a `@section` constant (SE-0492); IRGen knows the mangled name and can emit relative pointers but cannot synthesize the validator.

1. The **macro** emits one **accessor** per attribute - a captureless closure coerced to `_DistributedValidationAccessor` - into its own section (`swift5_davala`). `@section` forces SE-0492 static initialization so the C function pointer is in place at load. The accessor materializes a `RemoteCallValidator` into a caller-supplied out-pointer; strings, closures, arbitrary Swift expressions live here (normal function body, not a constant-expression context).
2. **IRGen** (`emitAccessibleFunction`, `lib/IRGen/GenDecl.cpp`) emits one **record** into `swift5_daval` per accessor, AND encodes a tagged relative pointer to the target's first record in the `Flags` field of the target's accessible-function record.

Record layout (`_DistributedValidationRecord`, four `i32` fields, 16-byte stride):

| Field | Meaning |
|-------|---------|
| `kind` | FourCC `'dval'` (for offline tooling; unused at runtime) |
| `reserved` | 0 |
| `relativeAccessor` | `RelativeDirectPointer` to the macro-emitted accessor |
| `relativeNext` | `RelativeDirectPointer` to the next record for this target, or `0` (end) |

The records are **never stride-walked**. The target's accessible-function record (which the runtime already resolves, by mangled name, to dispatch the call) carries a **tagged relative pointer** in its `Flags` field to this target's first validation record; further records chain via `relativeNext`. Both fields are 4-byte aligned, so the low two bits of the offset are free for the flag bits:

```
   accessible-function record .Flags  (i32)
     bit 0        = Distributed         (read by old runtimes; unchanged)
     bit 1        = HasValidation
     bits 2..31   = self-relative offset to the first swift5_daval record
                    (a multiple of 4; recovered as Flags & ~0x3)
```

Old runtimes read only bit 0 (`isDistributed`) and ignore the rest, and never look at validation, so this reuse is back-deploy-safe and does not change the accessible-function record's size.

```
   distributed actor MyActor
   ├── distributed func openDoor()          ← user-written
   ├── accessible-function record           ← IRGen, swift5_acfuncs
   │        └── Flags: HasValidation + rel ─┐
   ├── swift5_daval record 0 ←──────────────┘  ← IRGen, one per attribute
   │        ├── relativeNext ─┐
   │        └── relativeAccessor ─────────────┐
   ├── swift5_daval record 1 ←┘ (relativeNext=0)
   │        └── relativeAccessor ─┐           │
   └── __daval_openDoor_accessor ←┴───────────┘  ← macro, swift5_davala
```

Section names by object format (neither section is stride-walked; both only need to survive stripping):

| Format | Records (`swift5_daval`) | Accessors (`swift5_davala`) |
|--------|--------------------------|------------------------------|
| Mach-O | `__DATA_CONST,__swift5_daval`  | `__DATA_CONST,__swift5_davala`  |
| ELF / Wasm | `swift5_daval`             | `swift5_davala`                 |
| COFF   | `.sw5daval$B`                  | `.sw5davala$B`                  |

The accessor's name is compiler-issued via `context.makeUniqueName("__daval_<method>_accessor")` so multiple attributes on the same member (stacked `@Entitlement` + `@Entitlement`, or a witness-local attribute plus a protocol-inherited clone of the same kind) don't collide on invalid-redeclaration. IRGen finds the accessors by walking the target's peer declarations (`visitAuxiliaryDecls` on the original distributed func, recovered from its synthesized thunk), emits one record per accessor, threads them into the linked list, and points the `Flags` field at the first.

### Receive-side preflight

`DistributedActorSystem.executeDistributedTarget(on:target:...)` calls `DistributedValidation.preflight(on:target:)` before decoding arguments:

```
executeDistributedTarget
        │
        │ if #available(SwiftStdlib 6.5, *)
        ▼
   preflight(on:target:)
        │
        ▼
   lookup(targetIdentifier: target.identifier)
        │
        │ swift_distributed_getFirstValidationRecord: resolve the target's
        │ accessible-function record (swift_findAccessibleFunction), read its
        │ tagged Flags pointer -> first swift5_daval record (or nil)
        ▼
   walk the per-target linked list (relativeNext), materialize each validator,
   wrap them in one composite RemoteCallValidator
        ▼
   composite RemoteCallValidator.check()  -> throws on first failure (AllOf)
        ▼
   error propagates back to caller
```

There is **no section scan**. Identity is the accessible-function record's full mangled distributed-thunk name (collision-free, module-qualified), and `swift_findAccessibleFunction` already covers every loaded image on every platform, so validation works cross-image everywhere and is consistent with dispatch (concrete and protocol/`@Resolvable` targets alike). When the `HasValidation` bit is clear, `lookup` returns `nil` immediately - un-validated calls (the common case) pay only the accessible-function lookup they already do.

Failed preflight throws **directly** out of `executeDistributedTarget` - it does NOT go through `handler.onThrow(...)`. The target function has not run yet, so the error is not one the target produced.

Multiple records for the same target compose as **AllOf**: every validator must accept before the call runs. This arises from stacked attributes on the same distributed member and from the compiler's cross-module inheritance of a protocol requirement's attribute onto the conforming actor's witness (the witness ends up with both its own attribute and the inherited one). List order is implementation-defined, so the specific record whose error surfaces first is not guaranteed - but the AllOf outcome (accept iff every check accepts) is.

### Attribute inheritance across modules

The macros work identically whether written on a `distributed func` / `distributed var` directly, or on a protocol requirement that a distributed actor conforms to. In the protocol case the compiler transparently clones the attribute onto the concrete witness during conformance checking, and macro expansion runs on the witness as if the user had written the annotation there.

```
   Module A (producer)                         Module B (consumer)

   protocol HomeAdmin:                         distributed actor MyHome:
     DistributedActor {                          HomeAdmin {
                                                    typealias ActorSystem = ...
     @Entitlement("home.admin")
     distributed func openDoor() -> Bool         distributed func openDoor() -> Bool {
                                                    true
   }                                              }
                                                }
                                                    ▲
                                                    │ compiler inherits
                                                    │ @Entitlement onto witness,
                                                    │ macro expands the section
                                                    │ record here
```

Two mechanisms make this work: **`@preservedInInterface`** carries the attribute's argument text across module boundaries, and **`inheritDistributedValidationAttrs`** re-attaches it to the witness during conformance checking.

#### `@preservedInInterface`

An opt-in decl-attribute (`include/swift/AST/DeclAttr.def`) placed on the macro declaration itself. Two consequences:

- **Serialization** (`lib/Serialization/Serialization.cpp`): the extended `CustomDeclAttrLayout` stores the attribute's argument-list source text alongside the attribute record. `SWIFTMODULE_VERSION_MINOR` was bumped 1007 → 1008 for this layout change.
- **Interface printing** (`lib/AST/ASTPrinter.cpp`): the printer force-emits the argument list for `@preservedInInterface` macros, even in minimal-interface mode.

At deserialization time, `materializePreservedCustomAttrArgs` (`lib/Sema/TypeCheckMacros.cpp`) re-parses the preserved text on demand into a real `ArgumentList`. The text is deliberately NOT cleared after materialization; `inheritDistributedValidationAttrs` reads it again during witness synthesis.

#### `inheritDistributedValidationAttrs`

Runs from `checkDistributedActor` (`lib/Sema/TypeCheckDistributed.cpp`). For each `distributed func` / `distributed var` on the conforming actor, walks the protocol's requirements and clones allow-listed macro attributes (`@Entitlement`, `@ValidateRemoteCall`) onto the witness.

The clone has two paths:

**Same-module clone.** The requirement's `CustomAttr` carries valid source locations. Just build a new `CustomAttr` reusing the same `TypeExpr` and `ArgumentList`, `owner` retargeted to the witness. The peer macro plugin then walks the same `AttributeSyntax` node the user wrote on the protocol and emits the section record against the witness.

**Cross-module clone.** The requirement's `CustomAttr` was deserialized; its `AtLoc` is invalid and the plugin cannot find an `AttributeSyntax` node to walk. `synthesizeCustomAttrForWitness` builds a fresh source buffer containing `@<MacroName><preservedArgText>`, wraps it in a `SyntheticMacro`-kind `SourceFile`, and parses it. The resulting `CustomAttr` has valid locations pointing into the synthesized buffer and the plugin can walk it normally.

The synthesized buffer's `SourceFileKind` and `GeneratedSourceInfo::Kind` carry independent obligations:

- `SourceFileKind::SyntheticMacro` — makes `AvailabilityScope::createForSourceFile` walk `getEnclosingSourceFile()` and inherit availability from the witness's `DeclContext`. Without this, any reference to `@available(SwiftStdlib X, *)` API from inside the inherited attribute fails to type-check.
- `GeneratedSourceInfo::AttributeFromClang` — the only kind whose parser dispatch calls `parseExpandedAttributeList`. Despite the name (chosen historically for ClangImporter's `__attribute__((swift_attr))` handling), the code path is not Clang-specific.

The witness's peer expansion must observe the merged (local + inherited) attribute list on its single, cached evaluation. That is guaranteed by a hook at the top of `ExpandPeerMacroRequest::evaluate` (`lib/Sema/TypeCheckMacros.cpp`): before iterating a distributed witness's attributes, it calls `inheritDistributedValidationAttrs` on the enclosing distributed actor, cloning any not-yet-present inherited attributes. Because the request is evaluated exactly once and this runs before `forEachAttachedMacro`, both a witness-local attribute and a same-kind inherited one (e.g. local `@Entitlement("local")` + inherited `@Entitlement("proto")`) each get their own section record. The clone uses `LookupDirectFlags::ExcludeMacroExpansions` on its own witness lookup, so it cannot recurse back into the peer request. `TypeChecker::checkDistributedActor` also calls `inheritDistributedValidationAttrs` directly (after `getDefaultInitializer`, so it never forces early expansion of a cross-module synthesized attribute); the two call sites are idempotent (deduped by spelled name + argument source range).

### Public API

All 6.5-available. The record-shape typealiases stay underscored because they name the wire ABI of the section, not user-facing API.

```swift
public enum EntitlementPolicy: ExpressibleByStringLiteral {
  case entitlement(String)
  case anyOf([EntitlementPolicy])   // empty is vacuously false
  case allOf([EntitlementPolicy])   // empty is vacuously true
}

public struct EntitlementCheckFailed: Error, Codable, CustomStringConvertible {
  public var missing: String
}

public struct RemoteCallValidator: Sendable {
  public var check: @Sendable () throws -> Void
  public init(_ check: @escaping @Sendable () throws -> Void)
  public init(_ validator: RemoteCallValidator)    // pass-through
}

public enum DistributedValidation {
  @TaskLocal public static var currentEntitlements: Set<String>
  public static func evaluate(_ policy: EntitlementPolicy) throws
  public static func preflight<Act: DistributedActor>(
    on actor: Act, target: RemoteCallTarget) throws
  public static func lookup(
    targetIdentifier: String) -> RemoteCallValidator?
}

@preservedInInterface
@attached(peer, names: arbitrary)
public macro Entitlement(_ policy: EntitlementPolicy)

@preservedInInterface
@attached(peer, names: arbitrary)
public macro ValidateRemoteCall(_ validator: sending () throws -> Void)

@preservedInInterface
@attached(peer, names: arbitrary)
public macro ValidateRemoteCall(_ validator: RemoteCallValidator)
```

### Actor-system responsibilities

The distributed actor system implementer sets the task-local `DistributedValidation.currentEntitlements` set before calling `executeDistributedTarget`. The design pattern is "carry entitlements in the envelope / service context": on the receive side, decode the caller's identity from the wire envelope, resolve to a set of granted entitlements, and:

```swift
try await DistributedValidation.$currentEntitlements.withValue(
  callerEntitlements
) {
  try await self.executeDistributedTarget(
    on: actor, target: target, invocationDecoder: &decoder, handler: handler)
}
```

An empty set is treated as "caller has no entitlements". A target with no annotation is a no-op: `preflight` returns without doing anything (`HasValidation` is clear, so `lookup` returns `nil` after only the accessible-function resolution the call already performs).

### Known limitations (v1)

- **`@ValidateRemoteCall({...})` inline closure on a protocol requirement is rejected at macro-expansion time.** Cross-module closure re-parse trips a `PreCheckTarget` invariant. Named factory extensions on `RemoteCallValidator` are the supported spelling for cross-module use.

### Future directions

- **Enforce validation directly in the distributed accessor.** IRGen already knows, when it emits the distributed thunk accessor, whether the target carries validation attributes. Instead of the receive-side lookup, IRGen could emit the "resolve and run the validator" sequence inline in the accessor body, making enforcement unbypassable and eliminating the runtime lookup entirely for the enforcement path. The `swift5_daval` records would remain for optional sender-side pre-flight and tooling. This is a larger change and is deferred.