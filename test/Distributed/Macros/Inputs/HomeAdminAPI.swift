// Producer-side module used by
// `distributed_macro_validation_cross_module_binary.swift` and
// `distributed_macro_validation_cross_module_interface.swift`.
//
// Declares a distributed protocol whose requirement carries `@Entitlement`.
// The `@Entitlement` macro opts into serialization preservation via
// `@preservedInInterface`, so both the attribute and its argument list
// survive to the consuming module regardless of whether that module loads
// this one directly from `.swiftmodule` or via re-parsed `.swiftinterface`.

import Distributed
import FakeDistributedActorSystems

@available(SwiftStdlib 6.5, *)
public protocol HomeAdmin: DistributedActor where ActorSystem == FakeRoundtripActorSystem {
  @Entitlement("com.example.cross-module")
  distributed func openDoor() -> Bool

  @Entitlement(.anyOf(
    "com.example.cross-module",
    "com.example.admin",
  ))
  distributed func openAdminDoor() -> Bool

}
