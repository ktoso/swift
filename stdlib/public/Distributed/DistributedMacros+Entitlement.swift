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
// PoC of @Entitlement macro. This would not be included in upstream Swift.
//===----------------------------------------------------------------------===//

// Macros are disabled when Swift is built without swift-syntax.
#if $Macros && hasAttribute(attached)

import Swift
import _Concurrency

// ==== -----------------------------------------------------------------------
// MARK: @Entitlement
//
// See `DistributedValidation+Entitlement.swift` for the `EntitlementPolicy`
// enum these macros produce, the receive-side task-local set, and the
// evaluator that turns a policy tree into an accept/reject decision.

/// Requires the caller of a `distributed func` or `distributed var` to carry
/// the specified entitlement. The check is evaluated by the receiving
/// `DistributedActorSystem` **before** arguments are decoded and before the
/// target method is invoked.
///
/// Applied to a protocol requirement, `@Entitlement` is inherited onto every
/// witness of that requirement on conforming distributed actors, without
/// requiring the conformer to restate the attribute. A conforming method
/// cannot opt-out from an entitlement enforced by a protocol it implements.
///
/// A bare string literal is accepted as sugar for the single-entitlement case
/// via `EntitlementPolicy`'s `ExpressibleByStringLiteral` conformance:
///
///     @Entitlement("read-only")            // single entitlement
///     @Entitlement(.anyOf(["a", "b"]))     // structured policy
///
/// ### Combining entitlement checks
/// Applying the @Entitlement attribute multiple times to the same distributed function
/// is equivalent to requiring all of the spelled out entitlements:
/// ```
/// @Entitlement("read-only") // AND
/// @Entitlement("all-access")
/// distributed func verify()
/// ```
///
/// If you want to express "only one of them must be valid" use the following pattern:
///
/// ```
/// @Entitlement(.anyOf(["read-only", /* OR */ "all-access"]))
/// distributed func verify()
/// ```
///
/// ### Restrictions
///
/// - Can only be applied to a `distributed func` or `distributed var`.
///   Applying it to any other declaration is a compile-time error.
@preservedInInterface
@available(SwiftStdlib 6.5, *)
@attached(peer, names: arbitrary)
public macro Entitlement(_ policy: EntitlementPolicy) =
  #externalMacro(module: "SwiftMacros", type: "EntitlementMacro")

#endif
