//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020-2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
// Macros supporting distributed actor features.
//===----------------------------------------------------------------------===//

import Swift
import _Concurrency

// Macros are disabled when Swift is built without swift-syntax.
#if $Macros && hasAttribute(attached)

// ==== -----------------------------------------------------------------------
// MARK: @DistributedValidatorMacro (marker generator)

/// Marks a `macro` declaration as a receive-side remote-call validation macro
/// so a distributed actor system can opt into inheriting it. Attach it to the
/// macro declaration; it generates a marker type `<MacroName>Macro` conforming
/// to ``DistributedRemoteCallValidationMacroIdentifier`` (e.g. `@DistributedValidatorMacro` on
/// `macro Entitlement` generates `enum EntitlementMacro`). The actor system
/// then lists that marker in `DistributedRemoteCallValidation.InheritMacros<...>`.
@available(SwiftStdlib 6.5, *)
@attached(peer, names: suffixed(Macro))
public macro DistributedValidatorMacro() =
  #externalMacro(module: "SwiftMacros", type: "RemoteCallValidationMarkerMacro")

// ==== -----------------------------------------------------------------------
// MARK: @Resolvable

/// Enables the attached to protocol to be resolved as remote distributed
/// actor reference.
///
/// ### Requirements
///
/// The attached to type must be a protocol that refines the `DistributedActor`
/// protocol. It must either specify a concrete `ActorSystem` or constrain it
/// in such way that the system's `SerializationRequirement` is statically known.
@attached(peer, names: prefixed(`$`)) // provides $Greeter concrete stub type
@attached(extension, names: arbitrary) // provides extension for Greeter & _DistributedActorStub
public macro Resolvable() =
  #externalMacro(module: "SwiftMacros", type: "DistributedResolvableMacro")

// ==== -----------------------------------------------------------------------
// MARK: @ValidateRemoteCall

/// Attaches a named ``RemoteCallValidator`` recipe to the receive side of a
/// distributed call. Extend ``RemoteCallValidator`` with static factories
/// (constrained by `where ActorSystem == MySystem`) and reference them via
/// implicit-member syntax:
///
///     extension RemoteCallValidator where ActorSystem == MySystem {
///       public static var requireAdminRole: RemoteCallValidator {
///         RemoteCallValidator { _ in /* check task-local entitlements */ }
///       }
///     }
///
///     distributed actor SecureHome {
///       @ValidateRemoteCall(.requireAdminRole)
///       distributed func openBackDoor() -> Bool { true }
///     }
///
/// Applied to a protocol requirement, `@ValidateRemoteCall` is inherited onto
/// every witness of that requirement on conforming distributed actors.
///
/// The macro parameter is deliberately untyped (`_ validator: Any`) so the
/// implicit-member `.name` syntax parses uniformly whether the attachment
/// site is a concrete distributed method (where `Self.ActorSystem` is known)
/// or a protocol requirement (where it is not). Actual validity is enforced
/// by the peer accessor the macro emits, which types the value as
/// `RemoteCallValidator<Self.ActorSystem>` - so an extension of
/// ``RemoteCallValidator`` that isn't visible under the enclosing actor's
/// system fails the accessor's type-check with the usual "no member" error.
///
/// ### Restrictions
///
/// - Can only be applied to a `distributed func` or `distributed var`.
///   Applying it to any other declaration is a compile-time error.
/// - Only the named-factory form is supported. Inline closures cannot be
///   used, because the validator body depends on the enclosing actor
///   system's ``DistributedActorSystem/RemoteCallValidationContext`` and
///   ``DistributedActorSystem/RemoteCallValidationFailure`` associated
///   types which are not in scope at the attribute-argument syntax
///   position. Factor the body into a static extension member on
///   ``RemoteCallValidator`` (see the example above) and reference it by
///   name.
/// The macro is generic over the actor system so implicit-member syntax
/// (`.myFactory`) at the attribute-argument site resolves against the
/// enclosing distributed actor's `ActorSystem`. When the attachment site is
/// a distributed protocol requirement, the requirement must fix
/// `ActorSystem` (either the protocol's `where ActorSystem == ...` constraint
/// or by using a validator factory whose extension pins a specific system)
/// so the macro's `ActorSystem` type parameter can be inferred.
@available(SwiftStdlib 6.5, *)
@preservedInInterface
@DistributedValidatorMacro
@attached(peer, names: arbitrary)
public macro ValidateRemoteCall<ActorSystem: DistributedActorSystem>(
  _ validator: RemoteCallValidator<ActorSystem>
) =
  #externalMacro(module: "SwiftMacros", type: "ValidateRemoteCallMacro")

#endif
