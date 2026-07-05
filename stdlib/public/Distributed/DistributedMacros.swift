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

/// Runs a user-supplied validation on the receiving side of a remote call,
/// before arguments are decoded and before the target method is invoked.
/// Throwing from the validator aborts the call and propagates the error to
/// the caller as a codable error.
///
/// Applied to a protocol requirement, `@ValidateRemoteCall` is inherited onto
/// every witness of that requirement on conforming distributed actors.
///
/// ### Restrictions
///
/// - Can only be applied to a `distributed func` or `distributed var`.
///   Applying it to any other declaration is a compile-time error.
@available(SwiftStdlib 6.5, *)
@preservedInInterface
@attached(peer, names: arbitrary)
public macro ValidateRemoteCall(_ validator: sending () throws -> Void) =
  #externalMacro(module: "SwiftMacros", type: "ValidateRemoteCallMacro")

/// Attaches a named ``RemoteCallValidator`` recipe to the receive side of a
/// distributed call. Extend ``RemoteCallValidator`` with static factories to
/// build reusable validation recipes shared across many actors:
///
///     extension RemoteCallValidator {
///       public static var requireAdminRole: RemoteCallValidator {
///         RemoteCallValidator { /* check task-local entitlements */ }
///       }
///     }
///
///     distributed actor SecureHome {
///       @ValidateRemoteCall(.requireAdminRole)
///       distributed func openBackDoor() -> Bool { true }
///     }
///
/// See ``ValidateRemoteCall(_:)-Wrapper`` for the closure form.
@available(SwiftStdlib 6.5, *)
@preservedInInterface
@attached(peer, names: arbitrary)
public macro ValidateRemoteCall(_ validator: RemoteCallValidator) =
  #externalMacro(module: "SwiftMacros", type: "ValidateRemoteCallMacro")

#endif
