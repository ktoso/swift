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
// The composite `@Entitlement(.anyOf(...))` form spells the type name and
// module qualifier explicitly. The client's macro expansion emits the arg
// text verbatim; without the explicit qualifier, the `.anyOf(...)` short
// form would need contextual resolution against `_EntitlementPolicy`,
// which is harder to guarantee at cross-module expansion time.

import Distributed
import FakeDistributedActorSystems

@available(SwiftStdlib 6.5, *)
public protocol HomeAdmin: DistributedActor where ActorSystem == FakeRoundtripActorSystem {
  // Bare string literal form: `_EntitlementPolicy` conforms to
  // `ExpressibleByStringLiteral`, so `"..."` desugars to
  // `.entitlement("...")`.
  @Entitlement("com.example.cross-module")
  distributed func openDoor() -> Bool

  // Composite policy: qualifier + type name + case.
  @Entitlement(Distributed._EntitlementPolicy.anyOf([
    .entitlement("com.example.cross-module"),
    .entitlement("com.example.admin"),
  ]))
  distributed func openDoorAnyOf() -> Bool
}
