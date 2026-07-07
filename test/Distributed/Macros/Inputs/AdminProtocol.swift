// Producer-side module used by
// `distributed_macro_validation_cross_module_binary.swift` and
// `distributed_macro_validation_cross_module_interface.swift`.
//
// Declares a distributed protocol whose requirement carries `@Entitlement`.
// The `@Entitlement` macro opts into serialization preservation via
// `@preservedInInterface`, so both the attribute and its argument list
// survive to the consuming module regardless of whether that module loads
// this one directly from `.swiftmodule` or via re-parsed `.swiftinterface`.
//
// Four shapes are tested:
//   1. Bare string literal (`"..."`) - desugared to `.entitlement("...")`
//      via `ExpressibleByStringLiteral`.
//   2. Fully-qualified composite (`Distributed.EntitlementPolicy.anyOf(...)`)
//      - the exact user source text round-trips verbatim on the binary
//      `.swiftmodule` path.
//   3. Bare implicit-member composite (`.anyOf([...])`) - resolves via
//      contextual type binding against the macro's declared
//      `EntitlementPolicy` parameter. On the binary path the arg text
//      arrives as-is at the witness and the macro plugin wraps it in
//      `(...) as Distributed.EntitlementPolicy` so implicit-member syntax
//      binds. On the interface-rebuild path the interface printer resolves
//      the implicit member against the parameter type at print time and
//      emits `Distributed::EntitlementPolicy.anyOf([Distributed::
//      EntitlementPolicy.entitlement(...), ...])`; the same wrap makes the
//      qualified form type-check equivalently. Both paths produce
//      identical runtime policies.
//   4. Variadic implicit-member composite (`.anyOf(a, b)`, no array literal)
//      - resolves to the variadic `EntitlementPolicy.anyOf(_:)` factory. The
//      bracket-less spelling round-trips the same way as shape 3.

import Distributed
import FakeDistributedActorSystems

// `@ValidateRemoteCall` with a named factory reference is inherited across
// modules the same way `@Entitlement` is. Inline closures on protocol
// requirements are rejected at macro-expansion time - the closure body would
// be captured verbatim in `preservedArgText` and re-parsed at the witness
// site, but the parsed `ClosureExpr`'s parent `DeclContext` doesn't match
// the witness's DC, tripping a compiler invariant in `PreCheckTarget`. Named
// factories don't need to preserve an inline expression tree, so they work
// cleanly.
//
// The extension carries `@available(SwiftStdlib 6.5, *)` because
// `RemoteCallValidator`, `DistributedValidation.currentEntitlements`, and
// `EntitlementCheckFailed` are 6.5-available. The synthesized inherited-
// attribute buffer created at the witness site inherits the witness's
// availability context (via `SourceFileKind::SyntheticMacro` in
// `inheritDistributedValidationAttrs`), so as long as the consumer's
// witness sits inside a `@available(SwiftStdlib 6.5, *)` context the
// factory reference type-checks with no additional gymnastics.
@available(SwiftStdlib 6.5, *)
extension Distributed.RemoteCallValidator {
  public static var requireCustomEntitlement: Distributed.RemoteCallValidator {
    Distributed.RemoteCallValidator {
      guard Distributed.DistributedValidation.currentEntitlements.contains(
        "com.example.custom-validator"
      ) else {
        throw Distributed.EntitlementCheckFailed(missing: "custom-validator")
      }
    }
  }
}

@available(SwiftStdlib 6.5, *)
public protocol HomeAdmin: DistributedActor where ActorSystem == FakeRoundtripActorSystem {
  // Bare string literal form: `EntitlementPolicy` conforms to
  // `ExpressibleByStringLiteral`, so `"..."` desugars to
  // `.entitlement("...")`.
  @Entitlement("com.example.cross-module")
  distributed func openDoor() -> Bool

  // Composite policy: qualifier + type name + case.
  @Entitlement(Distributed.EntitlementPolicy.anyOf([
    .entitlement("com.example.cross-module"),
    .entitlement("com.example.admin"),
  ]))
  distributed func openDoorAnyOf() -> Bool

  // Short-form composite policy: leading `.anyOf(...)` with no explicit type
  // prefix. Depends on contextual resolution against `EntitlementPolicy` at
  // the witness site, which the macro plugin arranges via the
  // `(...) as Distributed.EntitlementPolicy` wrap.
  @Entitlement(.anyOf([
    .entitlement("com.example.short-form-a"),
    .entitlement("com.example.short-form-b"),
  ]))
  distributed func openDoorShortAnyOf() -> Bool

  // Variadic short-form: `.anyOf(...)` with the nested policies listed
  // directly (no array literal). Resolves to the variadic
  // `EntitlementPolicy.anyOf(_:)` factory rather than the `.anyOf([...])`
  // case; the preserved arg text round-trips the bracket-less spelling to
  // the witness, exercising the factory across the module boundary.
  @Entitlement(.anyOf(
    .entitlement("com.example.variadic-a"),
    .entitlement("com.example.variadic-b"),
  ))
  distributed func openDoorVariadicAnyOf() -> Bool

  // `@ValidateRemoteCall` with a named factory. The producer defines the
  // factory as a static member of `RemoteCallValidator`; the consumer just
  // references it via implicit-member syntax, which resolves against the
  // (imported) extension at the witness site.
  @ValidateRemoteCall(.requireCustomEntitlement)
  distributed func openDoorCustom() -> Bool
}
