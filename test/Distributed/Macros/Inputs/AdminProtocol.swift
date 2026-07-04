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
// Three shapes are tested:
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

import Distributed
import FakeDistributedActorSystems

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
}
