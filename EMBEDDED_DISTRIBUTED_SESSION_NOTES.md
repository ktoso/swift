# Distributed Actors in Embedded Swift — session notes

Working notes for resuming work on `wip-distributed-embedded`. Committed on this
branch so it travels with the work, rather than as a stray untracked file. Drop
it before the series goes up for review.

Last updated: 2026-08-31.

---

## 1. Where things stand

| | |
|---|---|
| Branch | `wip-distributed-embedded` |
| Tip | `9d00efc1275` |
| Base | `main` @ `8ed72dd1763` (2026-08-29 22:00, `== origin/main`) |
| Position | 39 commits ahead, **0 behind** |
| Pre-rebase backup | tag `backup-wip-distributed-embedded-20260830` -> `065b6157a12` |
| Remote | `ktoso/wip-distributed-embedded` is **stale** (still the pre-rebase tip). Nothing pushed since. No PR. |

Nothing from this work has landed on `main`
(`git grep EmbeddedDistributedActorSystem main` is empty).

**Steps 0-2 of the plan are done.** Phase 1 (parallel protocol family +
synthesized receive dispatch) and Phase 2 (`any P` with `@Resolvable`) were
already functionally complete before this session; this session rebased them
onto current `main`, made the test suite actually execute, fixed two real bugs
that the dead test suite had been hiding, and lifted the single-file
restriction.

### Update (2026-08-31): protocol collapse for source portability

The parallel `EmbeddedDistributedActorSystem` +
`EmbeddedDistributedTargetInvocation{Encoder,Decoder,ResultHandler}` protocol
family was **removed**. Its embedded shape now lives inside the single
`DistributedActorSystem` family via an `#if $Embedded` branch in
`stdlib/public/Distributed/DistributedActorSystem.swift` (the `#else` branch is
byte-identical to the shipping non-embedded family). `DistributedActor` keeps
one name too; its `#if $Embedded` branch just drops the `SerializationRequirement`
associated type. A `distributed actor` and its actor-system conformance clause
are now source-portable across the two modes - only the serialization layer
(encoder/decoder/handler members and `remoteCall` signatures) stays
mode-specific, `#if`-split by the user.

Compiler side: the embedded distributed shape is no longer selected by a
separate conformance or a named predicate; each site checks
`actor->isDistributedActor() && LangOpts.hasFeature(Feature::Embedded)`
inline. The four `PROTOCOL(EmbeddedDistributed*)`
`KnownProtocolKind`s and their `ASTContext`/`GenMeta` cases are gone, the
ad-hoc-requirement checker is gated off embedded shapes, and `checkDistributedActorSystem`
early-returns under embedded (no `SerializationRequirement` to look up). The
error struct `EmbeddedDistributedTargetNotFound` and the C++ symbol names
(`checkEmbeddedDistributedFunctionCoverage`, `synthesizeEmbeddedDistributedReceiveDispatch`,
`ResolveEmbeddedDistributedReceiveDispatch`) were kept as-is.

### Update (2026-08-31): stop recording the return type under Embedded

The embedded thunk no longer emits `encoder.recordReturnType(R.self)`, and the
coverage checker no longer requires a `recordReturnType(_:)` overload on the
user's encoder. The return type carries no wire metadata under Embedded: the
receiver-side dispatch already knows each target's concrete return type
statically from the mangled target name, and the sender decodes the result via
`decoder.decodeNextArgument(R.self)`. Changes: the synthesis block in
`deriveBodyDistributed_thunk` is gated `!isEmbeddedSystem`
(`lib/Sema/CodeSynthesisDistributedActor.cpp`), the recordReturnType coverage
check is removed from `checkEmbeddedDistributedFunctionCoverage`
(`lib/Sema/TypeCheckDistributed.cpp`), and the now-unused
`distributed_embedded_missing_record_return_type` diagnostic is deleted from
`include/swift/AST/DiagnosticsSema.def`. `decodeReturnType`/`decodeErrorType`
were already never emitted on the embedded path (they live only in the
non-embedded `executeDistributedTarget`), so no change there. The embedded test
encoders dropped their now-dead `recordReturnType` overloads accordingly.

### Test results at `9d00efc1275`

| Suite | Result |
|---|---|
| `test/Distributed/Embedded/` | **16 / 16 passed** |
| `test/Distributed/` + `test/embedded/` | **505 passed, 0 failed**, 47 unsupported (552 total) |
| `test/decl/` + `test/Sema/` | 714 passed, 3 failed — **pre-existing**, see §6 |

All four embedded executables were additionally run by hand to confirm they
really execute rather than merely compile:

```
roundtrip_exec                  -> remoteCall reached / result: Hello, World!
resolvable_any_roundtrip_exec   -> remoteCall reached x2 / dispatch result: worked: world
synthesized_dispatch_exec       -> remoteCall reached / result: Hello, World!
multifile_dispatch_exec (a.out) -> hello: Hello, World! / farewell: Goodbye, World!
multifile_dispatch_exec (b.out) -> same (reverse file order)
```

### The six commits added this session

| SHA | Summary |
|---|---|
| `7a6b9fff587` | Guard three new upstream `DistributedActorSystem` decls under `#if !$Embedded` |
| `43b8d96ad04` | Fix undefined `getClassObject` in the embedded remote-init (real link bug) |
| `6837fc9436b` | Make the embedded tests actually run (bogus `REQUIRES` + threading shim) |
| `e1f359a92d3` | Correct the stale remote-proxy trim description |
| `e8b3e8e4c21` | Cross-file `_executeDistributedTarget` via lazy member synthesis |
| `9d00efc1275` | Document the lazy synthesis path and the `distributed var` gap |

The 33 commits below these are the original branch work, 17 of them still
`[wip]`-prefixed and needing rewrite before review (deferred, §5 Step 6).

---

## 2. Build and test recipes

Build dir: `build/Ninja-RelWithDebInfoAssert/swift-macosx-arm64`.

**Order matters.** Build `swift-frontend` first, then the libraries. Reversing
it leaves modules stale and produces spurious `compiled module was created by an
older version of the compiler` failures all over unrelated suites.

```bash
cd build/Ninja-RelWithDebInfoAssert/swift-macosx-arm64
ninja swift-frontend 2>&1 | tee /tmp/embdist-build-$(date +%s).log | tail -5
ninja swiftCore-macosx swift_Concurrency-macosx swiftDistributed-macosx embedded-libraries
```

For a fast inner loop after touching only embedded distributed code, the
targeted set is enough:

```bash
ninja embedded-concurrency-arm64-apple-macos \
      embedded-concurrency-default-executor-arm64-apple-macos \
      embedded-distributed-arm64-apple-macos
```

Useful target families: `embedded-distributed{,-arm64-apple-macos,-arm64e-apple-macos,-x86}`,
`embedded-concurrency{,-default-executor,...}`, `embedded-libraries` (everything
embedded, all triples). Reach for `embedded-libraries` whenever *other* embedded
modules (Synchronization, Observation, Volatile, cxxshim) go stale.

Always confirm the non-embedded build too when touching shared files:
`ninja swiftDistributed-macosx swift_Concurrency-macosx`.

### Running the tests

Two environment tweaks are mandatory in this setup: strip `~/.swiftly/bin` from
`PATH` and unset `TOOLCHAINS`, or the link step dies with
`You have already set TOOLCHAINS environment variable to default, but swiftly
has picked another toolchain`.

```bash
CLEAN_PATH=$(echo "$PATH" | tr ':' '\n' | grep -v swiftly | paste -sd: -)
env -u TOOLCHAINS PATH="$CLEAN_PATH" \
  build/Ninja-RelWithDebInfoAssert/llvm-macosx-arm64/bin/llvm-lit -s \
  --param swift_site_config=build/Ninja-RelWithDebInfoAssert/swift-macosx-arm64/test-macosx-arm64/lit.site.cfg \
  test/Distributed/Embedded/
```

> The swiftly message is **also a red herring**: it appeared alongside genuine
> `Undefined symbols` link errors during this session. Always read past it to
> the real error block before blaming swiftly.

Prefer `-s`. Plain `-v` / `-sv` dumps the full `Available features:` list, which
is several thousand tokens per invocation.

---

## 3. What this session found

### 3.1 The whole embedded test suite had never run (most important)

All 15 tests under `test/Distributed/Embedded/` carried
`// REQUIRES: swift_in_compiler`. **That lit feature is defined nowhere in the
repository** — not `test/lit.cfg`, not `lit.site.cfg.in`, not CMake. An
undefined feature name silently marks a test `UNSUPPORTED` forever rather than
erroring, so every one of them had been skipped since the day it was written.
The suite reported "100% unsupported" and looked like it passed.

This is why the two bugs below survived: the author had reason to believe the
end-to-end round trip worked.

The marker was copied from 5 tests in `test/embedded/` that have the same latent
bug and are **also permanently skipped on `main`**:
`arc-opt-runtime-helpers.swift`, `cxx-std-vector.swift`,
`linkage/extern_c_thunk_no_interface_model.swift`,
`stdlib-c-interop-typealiases.swift`, `throw-get-code.swift`. Worth reporting
upstream separately — not fixed here.

The correct idiom, used by the other ~330 tests in `test/embedded/`, is
`swift_feature_Embedded` plus `optimized_stdlib` / `executable_test` / OS gates.

**Lesson:** when a test directory reports suspiciously high `UNSUPPORTED`, diff
every `REQUIRES` against the `Available features:` list lit prints.

### 3.2 `getClassObject()` link failure (was hidden by 3.1)

`swift_distributedActor_remote_initialize_embedded` in
`stdlib/public/Concurrency/Actor.cpp` called `actorType->getClassObject()`. The
only inline definition of `Metadata::getClassObject()` lives in
`stdlib/public/runtime/Private.h`, which Actor.cpp deliberately does **not**
include under `SWIFT_CONCURRENCY_EMBEDDED` (guard at Actor.cpp ~lines 27-31:
"Private.h pulls in the demangler and other hosted C++ facilities"). Since
`Metadata.h` only *declares* it, the call compiled fine and emitted an
unresolved external, so **every** embedded distributed executable failed to
link:

```
Undefined symbols for architecture arm64:
  "swift::TargetMetadata<swift::InProcess>::getClassObject() const",
    referenced from: _swift_distributedActor_remote_initialize_embedded
```

Fixed with `cast<ClassMetadata>(actorType)`: for `MetadataKind::Class` that
function is just a `static_cast`, and the ObjC-class-wrapper case cannot arise
under embedded (no ObjC interop).

**Lesson:** a declaration without a visible inline definition in embedded stdlib
C++ is a *link* error, not a compile error, so it only surfaces when an
executable test actually runs.

### 3.3 Embedded Concurrency now needs a threading shim (upstream drift)

Embedded executables linking `-lswift_Concurrency` need
`%target-embedded-concurrency-threading-shim` on the link line, or they fail
with undefined `__swift_mutexRecursive_init` / `__swift_mutexRecursive_destroy`
referenced from Task.cpp (`AsyncTask::~AsyncTask`, `swift_task_create_common`,
`AsyncTask::PrivateStorage::PrivateStorage`). The substitution is defined in
`test/embedded/lit.local.cfg` and resolves per platform (darwin:
`-lswiftEmbeddedPlatformMultiThreadedDarwin`). 26 `test/embedded/` tests already
used it; the four embedded distributed executables now do too.

### 3.4 New upstream `DistributedActorSystem` decls needed embedded guards

Three declarations added upstream to
`stdlib/public/Distributed/DistributedActorSystem.swift` are generic over, or
extensions of, `DistributedActorSystem`, which the embedded build marks
`@_unavailableInEmbedded` — and all three sit *outside* the file's existing
`#if !$Embedded` region:

1. the `resignRemoteID(_:)` default implementation (`@available(SwiftStdlib 6.5, *)`,
   tied to feature `DistributedActorResignRemoteID`)
2. `_validateMatchingInvocationDecoder`
3. `_validateMatchingResultHandler`

(2) and (3) are `@export(implementation)` internal generic funcs called from the
top of `executeDistributedTarget`. Each got its own local `#if !$Embedded`
rather than extending the existing region, so the guards survive future upstream
edits in that area.

**Careful:** `RemoteCallTarget`, which follows the validation helpers in that
file, must **stay** available under embedded — the embedded protocol family uses
it.

### 3.5 Cross-file `_executeDistributedTarget` (the Step 2 blocker)

`synthesizeEmbeddedDistributedReceiveDispatch` was only driven eagerly from
`TypeChecker::checkDistributedActor`, which runs per source file. A reference
from a *different* file in the same module could be resolved first, giving:

```
error: value of type 'Greeter' has no member '_executeDistributedTarget'
```

That is the common case, not a corner case: the actor system's `remoteCall` is
the natural caller, and a real actor system lives in its own file. The only
workaround was putting the system and every distributed actor in one file, which
is exactly why all 15 pre-existing tests are single-file.

Fixed by routing synthesis through lazy member synthesis, the same mechanism
`CodingKeys` / `Encodable` / `Decodable` use:

- `ImplicitMemberAction::ResolveEmbeddedDistributedReceiveDispatch`
  (`include/swift/AST/TypeCheckRequests.h`)
- handled in `ResolveImplicitMemberRequest` (`lib/Sema/CodeSynthesis.cpp`)
- dispatched from `NominalTypeDecl::synthesizeSemanticMembersIfNeeded`
  (`lib/AST/Decl.cpp`), matched on the **base name** so both the compound and
  bare spelling trigger it
- `simple_display` case added in `lib/AST/TypeCheckRequests.cpp` (`-Werror`
  `-Wswitch` will catch you if you forget)
- `Id_executeDistributedTarget` added to `include/swift/AST/KnownIdentifiers.def`
  via `IDENTIFIER_(executeDistributedTarget)`, so synthesis and lookup share one
  identifier

Two things that matter if this is ever revisited:

- **Idempotency is required.** The function now runs both eagerly and lazily, so
  it early-outs via `actor->lookupDirect(...Id_executeDistributedTarget)`.
  `lookupDirect` deliberately does not trigger synthesis, so this cannot
  recurse. The lookup table is keyed on `DeclBaseName`, so a simple-name lookup
  does find the compound-named member.
- **The eager call must stay.** SILGen still needs `SF->addDelayedFunction` to
  run for the actor's own file.

`-primary-file` needs no test coverage: embedded Swift requires whole-module
optimization, so a single frontend invocation always sees every file.

### 3.6 Stale docs corrected

`docs/Distributed.md` and a comment on `getDistributedRemoteActorAllocSize`
both still claimed the embedded remote proxy allocates the full instance size
and "over-allocates by the sum of user-defined property sizes". Commit
`b3ebdf8ef75` documented the trim as infeasible and the *later* `add91868f92`
went on to implement it; neither description was updated. The implemented design
is `swift_distributedActor_remote_initialize_embedded`, taking a size and
alignment mask precomputed by IRGen from `ClassLayout`
(`lib/IRGen/GenDistributed.cpp` lines ~57-80, under `Feature::Embedded`).

Verified while there that this is safe: under embedded, deallocation ignores
sizes entirely (`swift_deallocClassInstance(this, 0, 0)` in
`DefaultActorImpl::deallocateUnconditional`), so the trimmed allocation has no
alloc/dealloc mismatch.

---

## 4. Rebase notes (if it ever has to be redone)

The big rebase was 2457 commits (merge base 2026-06-29 -> `main` 2026-08-29) and
conflicted in only **3 files**. The second, smaller rebase onto `8ed72dd1763`
had zero conflicts.

1. **`stdlib/public/Distributed/DistributedActorSystem.swift`** — upstream added
   `@available(SwiftStdlib 5.7, *)` to `executeDistributedTarget` where the
   branch added `@_unavailableInEmbedded`. Keep **both**, `@available` first
   (matches `ContinuousClock.swift` / `Task+TaskExecutor.swift`; both orderings
   exist in-tree, this is style not semantics).
2. **`stdlib/public/Distributed/DistributedActor.swift`** — upstream **deleted**
   the ``/// - SeeAlso: `Actor` `` and ``/// - SeeAlso: `AnyActor` `` doc lines.
   Take upstream's deletion, keep the branch's `#if $Embedded` `DistributedActor`
   variant.
3. **`stdlib/public/Concurrency/Actor.cpp`, `swift_distributed_actor_is_remote`**
   — upstream refactored the non-embedded path to
   `classifyActorClass(swift_getObjectType(_actor))` + a switch over
   `ActorClassKind`, with an `isObjCTaggedPointer` guard. Keep that path
   **verbatim** and put the embedded path in the `#else`: embedded cannot use
   `classifyActorClass` because embedded `ClassMetadata` has no descriptor, so
   use `cast<ClassMetadata>(_actor->metadata)` + `isDefaultActorClass(metadata)`.
   Note the branch adds an embedded `isDefaultActorClass` stub returning `true`
   unconditionally (Actor.cpp ~line 2420, in the `#else` of the
   `#if !SWIFT_CONCURRENCY_EMBEDDED` guard), because every actor surviving to
   runtime metadata in embedded is a default actor.

General steer used throughout: **prefer the newer upstream code** and re-apply
the embedded branch on top of it, rather than keeping the branch's older
version of a refactored function.

---

## 5. What is left

### Step 3 — support `distributed var` (next up, approach already decided)

`distributed var` silently does not work end to end. The **sender** side is
fine: `checkDistributedActor` synthesizes the thunk via its `VarDecl` arm
(`lib/Sema/TypeCheckDistributed.cpp` ~line 1207). The **receiver** side is not:
the collection loop in `synthesizeEmbeddedDistributedReceiveDispatch`
(`lib/Sema/CodeSynthesisDistributedActor.cpp` ~line 1665) only walks
`dyn_cast<FuncDecl>(member)`, and a `distributed var`'s getter is an
`AccessorDecl` nested inside the `VarDecl`, never a direct member of the actor.
Result: no dispatch branch, so a remote `distributed var` read throws
`EmbeddedDistributedTargetNotFound` at runtime with no compile-time diagnostic.
There is **zero** `distributed var` coverage in `test/Distributed/Embedded/`.

Decision: **support it, do not diagnose it** — it is a shipped
distributed-actors feature and a silent runtime failure is the worst option.

- Add a `VarDecl` arm to that collection loop, checking `var->isDistributed()`
  and collecting `var->getDistributedThunk()`, mirroring the arm that already
  exists in `checkDistributedActor` so the two stay consistent.
- In `buildEmbeddedDispatchBranch`, emit a branch keyed on the **getter thunk's**
  mangled name whose body reads the property on `self` and hands the value to
  `resultHandler.onReturn(_:)`. No arguments to decode, so it is strictly
  simpler than a method branch.
- Extend `checkEmbeddedDistributedFunctionCoverage`
  (`lib/Sema/TypeCheckDistributed.cpp` ~line 740) to cover the getter's return
  type, so a missing `onReturn(_: T)` / `decodeNextArgument(_: T.Type)` is a
  compile-time error with the existing paste-ready fix-it.
- Tests: a `-verify` case for the coverage diagnostic, a `-emit-sil` case
  pinning the getter-thunk branch, and an executable round trip reading a
  `distributed var` off a remote reference.

### Step 4 — non-default-actor distributed actors (deferred)

They currently **trap at runtime**: `swift_nonDefaultDistributedActor_initialize`
is gated out, so `swift_distributedActor_remote_initialize` hits
`swift_unreachable` (`stdlib/public/Concurrency/Actor.cpp` ~lines 3021-3037). A
custom `unownedExecutor` on an embedded distributed actor is a crash with no
compile-time warning. Minimum fix: diagnose at the actor declaration site.

### Step 5 — dispatch performance (deferred, highest-yield optimization)

The synthesized receive dispatch is an if-chain over
`target.identifier.utf8.elementsEqual("<mangled>".utf8)`, bucketed by
`utf8.count`. Measured at `-O` via
`test/Distributed/Embedded/distributed_embedded_dispatch_microbench.swift`:

| Methods (N) | first branch | middle | last |
|---|---|---|---|
| 1 | ~310 ns | - | - |
| 4 | ~320 ns | ~680 ns | ~860 ns |
| 16 | ~310 ns | ~1.9 us | ~1.4 us |
| 64 | ~320 ns | ~4.7 us | ~10.7 us |

Two causes: `Sequence.elementsEqual` is iterator-based and does **not**
short-circuit on count (two 65-byte names differing at byte 60 cost 60
byte-reads per branch); and the `Tg5` specialization on `String.UTF8View` emits
a `swift_bridgeObjectRelease` per call.

Measured fix: a hand-rolled
`withUTF8 { buf in buf.count == N && memcmp(buf.baseAddress, "<mangled>", N) == 0 }`
over 10 distinct 65-byte names, hitting the last branch, is **~23 ns/call** —
roughly **85x** faster. Deferred alternatives: an 8-byte-slice hash switch, and
a per-actor identifier cache mirroring
`ConcurrentReadableHashMap<AccessibleFunctionCacheEntry>` in
`stdlib/public/runtime/AccessibleFunction.cpp`.

Keep the existing length bucketing; re-run the microbenchmark before and after
and update the table in `docs/Distributed.md`.

### Step 6 — commit hygiene before any PR (deferred)

17 of the 33 original commits are `[wip]`-prefixed. Rewrite into a reviewable
series. The remote `ktoso/wip-distributed-embedded` is stale and will need a
force-push (or a fresh branch).

### Known permanent limitations (not gaps — diagnosed on purpose)

- `some P` parameters and user-written generic `distributed func`s. Both need
  `recordGenericSubstitution(T.self)`, which has no embedded wire shape.
  Diagnosed as `distributed_embedded_some_param_not_supported` (with a "use
  'any P' instead" fix-it) and `distributed_embedded_generic_func_not_supported`.
- The coverage diagnostic scales linearly with API surface: every distinct type
  in any distributed signature needs 3-4 hand-written overloads, with no macro
  to generate them yet.

---

## 6. Pre-existing failures — do not chase these

Three tests fail in `test/decl/` and are **unrelated** to this work:

```
decl/async/objc.swift
decl/ext/issue-54900.swift
decl/memberwise_init_compat.swift
```

They fail with `compiled module was created by an older version of the compiler
... Swift.swiftmodule` followed by `Loading the standard library failed`, so the
compiler never reaches any member synthesis. Confirmed pre-existing by stashing
the branch's compiler changes, rebuilding `swift-frontend`, and reproducing the
same three failures. Rebuilding `swiftCore-macosx` does not clear them; it is a
chicken-and-egg between `swift-frontend` and the core stdlib module in this
incremental build directory.

Also expect 47 unsupported tests across `test/Distributed/` + `test/embedded/`
(cross-compilation triples, non-macOS gates) — that is normal.

---

## 7. Design reference

The full design writeup lives in **`docs/Distributed.md`**, section
`# Distributed in Embedded Swift`. It covers the four embedded constraints that
rule out the standard runtime, the single `DistributedActorSystem` protocol
family with its `#if $Embedded` branch, the sender and
receiver paths, Phase 2 `any P` handling, what is gated where, measured code
size and heap costs, and the open-work list. That doc is the source of truth;
this file is only the session/logistics layer on top of it.

Other key locations:

- `stdlib/public/Distributed/DistributedActorSystem.swift` — the single protocol family; the `#if $Embedded` branch is the embedded shape
- `lib/Sema/CodeSynthesisDistributedActor.cpp` — thunk + receive-dispatch synthesis
- `lib/Sema/TypeCheckDistributed.cpp` — coverage diagnostic, `checkDistributedActor`
- `lib/IRGen/GenDistributed.cpp` — embedded remote-init, skipped accessor emission
- `stdlib/public/Concurrency/Actor.cpp` — `is_remote`, remote-init entry points
- `stdlib/public/Distributed/CMakeLists.txt` — the embedded build target
- Code-size harness: `~/code/swift-distributed-embedded-poc/`
  (`Makefile`, `bench/`, `ANALYSIS.md`)

---

## 8. Resuming checklist

```bash
git checkout wip-distributed-embedded          # tip should be 9d00efc1275
git fetch origin main && git rebase main       # only if behind
cd build/Ninja-RelWithDebInfoAssert/swift-macosx-arm64
ninja swift-frontend
ninja swiftCore-macosx swift_Concurrency-macosx swiftDistributed-macosx embedded-libraries
# then the lit invocation from §2, expect 16/16
```

Then pick up **Step 3** (`distributed var`) per §5.
