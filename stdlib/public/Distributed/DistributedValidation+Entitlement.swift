//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
//
// The entitlement-policy runtime that backs `@Entitlement`:
//
//   - `EntitlementPolicy`: closed enum with `.entitlement(String)`,
//     `.anyOf(...)`, `.allOf(...)`.
//   - `EntitlementCheckFailed`: codable error thrown on rejection.
//   - `DistributedValidation.currentEntitlements`: receive-side task-local
//     `Set<String>`.
//   - `DistributedValidation.evaluate(_:)`: policy-tree walker.
//
// Generic validation infrastructure (record ABI, `RemoteCallValidator`,
// section walker, `lookup`, `validate`) lives in
// `DistributedValidation.swift`.
//
// The `@Entitlement` macro declarations live in
// `DistributedMacros+Entitlement.swift`.
//
//===----------------------------------------------------------------------===//

import Swift
import _Concurrency

// ==== -----------------------------------------------------------------------
// MARK: EntitlementPolicy

/// A structured entitlement check. Compose with `.anyOf` and `.allOf`.
///
/// Unlike ``RemoteCallValidator``, `EntitlementPolicy` is a closed algebra:
/// it carries only string identities and composition. Custom-code validation
/// belongs on `RemoteCallValidator` and is spelled via `@ValidateRemoteCall`.
@available(SwiftStdlib 6.5, *)
public enum EntitlementPolicy {
  /// Require exactly this entitlement.
  case entitlement(String)
  /// Pass if any of the nested policies pass.
  ///
  /// An empty `.anyOf([])` is vacuously false: it always throws
  /// `EntitlementCheckFailed(missing: "<anyOf>")`.
  case anyOf([EntitlementPolicy])
  /// Pass only if every nested policy passes.
  ///
  /// An empty `.allOf([])` is vacuously true: it always accepts.
  case allOf([EntitlementPolicy])

  /// Variadic short-hand for `.anyOf([...])`, so the nested policies can be
  /// listed without an array literal:
  ///
  ///     @Entitlement(.anyOf(.entitlement("a"), .entitlement("b")))
  ///
  /// `.anyOf()` is vacuously false, matching `.anyOf([])`. The array form
  /// (`.anyOf([...])`) still binds to the `anyOf(_:)` case; only a bare
  /// comma-separated list resolves to this factory
  public static func anyOf(_ policies: EntitlementPolicy...) -> EntitlementPolicy {
    .anyOf(policies)
  }

  /// Variadic short-hand for `.allOf([...])`, so the nested policies can be
  /// listed without an array literal:
  ///
  ///     @Entitlement(.allOf(.entitlement("a"), .entitlement("b")))
  ///
  /// `.allOf()` is vacuously true, matching `.allOf([])`. The array form
  /// (`.allOf([...])`) still binds to the `allOf(_:)` case; only a bare
  /// comma-separated list resolves to this factory
  public static func allOf(_ policies: EntitlementPolicy...) -> EntitlementPolicy {
    .allOf(policies)
  }
}

// A bare string literal is shorthand for the single-entitlement case:
//
//     @Entitlement("open-safe")
//     @Entitlement(.anyOf(["admin", "operator"]))
//
// Both forms are `EntitlementPolicy`; the literal form desugars to
// `.entitlement("open-safe")`. This lets the `@Entitlement(String)`
// overload be removed - there's now a single `EntitlementPolicy`-taking
// macro overload that accepts both string literals and structured policies.
@available(SwiftStdlib 6.5, *)
extension EntitlementPolicy: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) {
    self = .entitlement(value)
  }
}

// ==== -----------------------------------------------------------------------
// MARK: Failure surface

/// Error thrown when a distributed remote call fails an `@Entitlement`
/// check. The `missing` field names the entitlement whose absence caused
/// the failure (or `"<anyOf>"` when a composite `.anyOf` policy exhausted
/// its options).
@available(SwiftStdlib 6.5, *)
public struct EntitlementCheckFailed: Error, Codable, CustomStringConvertible {
  /// The name of the entitlement that the caller lacked. For composite
  /// `.anyOf` policies whose entire branch tree failed, this is `"<anyOf>"`
  /// rather than a specific entitlement name.
  public var missing: String

  /// Constructs the error naming a specific missing entitlement.
  public init(missing: String) { self.missing = missing }

  public var description: String {
    "Remote call rejected: missing entitlement '\(missing)'"
  }
}

// ==== -----------------------------------------------------------------------
// MARK: Task-local + evaluator

@available(SwiftStdlib 6.5, *)
extension DistributedValidation {

  /// Currently-granted entitlements for the receiving side of a remote call.
  /// The distributed actor system implementer is expected to set this
  /// task-local before calling `executeDistributedTarget` (see the design
  /// doc for the "carry entitlements in the envelope / service context"
  /// pattern). An empty set means the caller has no entitlements.
  @TaskLocal
  public static var currentEntitlements: Set<String> = []

  /// Evaluate an ``EntitlementPolicy`` tree against the current task-local
  /// entitlements. Throws `EntitlementCheckFailed` on rejection.
  ///
  /// Used by `@Entitlement`-emitted validator closures. Not called by the
  /// runtime directly; the closure the macro synthesizes for an
  /// `@Entitlement` record already invokes this internally when the
  /// runtime executes the resulting `RemoteCallValidator.check`.
  public static func evaluate(_ policy: EntitlementPolicy) throws {
    switch policy {
    case .entitlement(let name):
      guard currentEntitlements.contains(name) else {
        throw EntitlementCheckFailed(missing: name)
      }
    case .anyOf(let policies):
      var lastError: Error? = nil
      for sub in policies {
        do {
          try evaluate(sub)
          return                            // any one passing is enough
        } catch {
          lastError = error
        }
      }
      throw lastError ?? EntitlementCheckFailed(missing: "<anyOf>")
    case .allOf(let policies):
      for sub in policies { try evaluate(sub) }  // all must pass
    }
  }
}
