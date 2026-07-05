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
// Runtime-side machinery for @Entitlement / @ValidateRemoteCall:
//
//   - The ABI of records placed in the `swift5_daval` section by the compiler
//     (IRGen): `_DistributedValidationAccessor`, `_DistributedValidationRecord`,
//     `_DistributedValidationKind` FourCC. These record-shape typealiases stay
//     underscored because they name the wire ABI of the section, not
//     user-facing API.
//   - `RemoteCallValidator`: the receive-side value the accessor produces,
//     wrapping the closure the runtime ultimately invokes.
//   - `DistributedValidation`: the `executeDistributedTarget` preflight hook.
//     Generic - parameterized only in `RemoteCallValidator`; no
//     entitlement-specific state or logic lives here.
//
// There is NO section scan. A target's accessible-function record (which the
// runtime already resolves, by mangled name, to dispatch the call) carries a
// tagged relative pointer in its `Flags` field to this target's first
// validation record; the records for a target form a singly linked list via
// their `relativeNext` field. So validation is keyed by the full mangled
// distributed-thunk name (collision-free) and, because the accessible-function
// lookup already covers every loaded image on every platform, validation works
// cross-image without any per-platform section walking.
//
// Entitlement-specific pieces (`EntitlementPolicy`, `EntitlementCheckFailed`,
// the receive-side task-local entitlement set, the entitlement evaluator)
// live in `DistributedValidation+Entitlement.swift`.
//
//===----------------------------------------------------------------------===//

import Swift

// ==== -----------------------------------------------------------------------
// MARK: Record layout

/// The C function pointer stored (indirectly) in a
/// `_DistributedValidationRecord`. When invoked by the Distributed runtime it
/// must materialize a value describing the validation policy for the record's
/// target into `outValue`, and return `true`. If it cannot (e.g. the `type`
/// argument does not match), it must leave `outValue` uninitialized and return
/// `false`.
public typealias _DistributedValidationAccessor = @convention(c) (
  _ outValue: UnsafeMutableRawPointer,
  _ type: UnsafeRawPointer,
  _ hint: UnsafeRawPointer?,
  _ reserved: UInt
) -> CBool

/// One record placed in the `swift5_daval` section by the compiler (IRGen),
/// one per `@Entitlement` / `@ValidateRemoteCall` on a distributed member.
///
/// Records are NOT stride-walked. Each target's accessible-function record
/// carries a tagged relative pointer (in its `Flags` field) to this target's
/// first record; further records for the same target are chained via
/// `relativeNext`.
///
/// Fields (all 4 bytes; total stride 16 bytes on every target):
///   - `kind`: `_DistributedValidationKind` FourCC (for offline tooling that
///     scans the section; unused at runtime).
///   - `reserved`: currently 0.
///   - `relativeAccessor`: a `RelativeDirectPointer` to the macro-emitted
///     `_DistributedValidationAccessor` global (in `swift5_davala`). Loading
///     through it yields the C function pointer to invoke.
///   - `relativeNext`: a `RelativeDirectPointer` to the next record for this
///     target, or `0` (a self-relative offset of 0 is never valid, so it is an
///     unambiguous end-of-list sentinel).
///
/// The relative pointers are signed byte offsets from the address of their own
/// field (see `_relativePointer`); they are decoded manually because Swift
/// cannot express `RelativeDirectPointer` as a stored tuple element.
public typealias _DistributedValidationRecord = (
  kind: UInt32,
  reserved: UInt32,
  relativeAccessor: Int32,
  relativeNext: Int32
)

/// FourCC discriminator identifying the interpretation of a record found in
/// the `swift5_daval` section. Distributed defines `.validation`; other kinds
/// may be added in the future or by third-party tooling.
@frozen
public struct _DistributedValidationKind: Sendable, RawRepresentable, Equatable {
  public var rawValue: UInt32

  @inlinable
  public init(rawValue: UInt32) {
    self.rawValue = rawValue
  }

  /// `'dval'` = distributed actor validation.
  ///
  /// Records with this kind carry a validation policy (entitlement check,
  /// custom validator, or a composition thereof) for a single distributed
  /// func or distributed var on a specific distributed actor type.
  @inlinable
  public static var validation: Self { .init(rawValue: 0x6476616c) }
}

// ==== -----------------------------------------------------------------------
// MARK: RemoteCallValidator

/// A named, reusable receive-side validation policy for a distributed
/// method, applied via `@ValidateRemoteCall`.
///
/// Extend this type with static factory members to reference them via
/// implicit-member syntax:
///
///     extension RemoteCallValidator {
///       public static var requireAdminRole: RemoteCallValidator {
///         RemoteCallValidator {
///           guard DistributedValidation.currentEntitlements.contains("admin")
///           else { throw EntitlementCheckFailed(missing: "admin") }
///         }
///       }
///
///       public static func requireEntitlement(_ name: String) -> RemoteCallValidator {
///         RemoteCallValidator {
///           guard DistributedValidation.currentEntitlements.contains(name)
///           else { throw EntitlementCheckFailed(missing: name) }
///         }
///       }
///     }
///
///     distributed actor SecureHome {
///       @ValidateRemoteCall(.requireAdminRole)
///       distributed func openBackDoor() -> Bool { true }
///
///       @ValidateRemoteCall(.requireEntitlement("open-safe"))
///       distributed func openSafe() -> Bool { true }
///     }
@available(SwiftStdlib 6.5, *)
public struct RemoteCallValidator: Sendable {
  /// The closure invoked on the receive side, before argument decoding, to
  /// validate the incoming remote call. Throwing rejects the call and
  /// propagates the error to the caller.
  public var check: @Sendable () throws -> Void

  /// Wraps a validator closure or top-level function reference.
  public init(_ check: @escaping @Sendable () throws -> Void) {
    self.check = check
  }

  /// Pass-through initializer. Enables the macro plugin's emission to
  /// funnel both `@ValidateRemoteCall({ ... })` and
  /// `@ValidateRemoteCall(.namedRecipe)` through a single code path.
  public init(_ validator: RemoteCallValidator) {
    self.check = validator.check
  }
}

// ==== -----------------------------------------------------------------------
// MARK: Runtime namespace

/// Namespace for runtime-side machinery that resolves validation policies for
/// a given distributed target, identified by its mangled distributed-thunk
/// name (`RemoteCallTarget.identifier`).
///
/// Policy-specific state and behavior - the entitlement task-local, the
/// policy evaluator - live as extensions in
/// `DistributedValidation+Entitlement.swift`.
///
/// The `swift5_daval` record layout is **ABI-committed**: the compiler emits
/// records here and this code reads them; the two must agree.
@available(SwiftStdlib 6.5, *)
public enum DistributedValidation {}

/// Given a distributed target's mangled name, return a pointer to its first
/// `swift5_daval` validation record, or `nil` if the target carries no
/// validation. Implemented in the Distributed runtime: it resolves the
/// target's accessible-function record and follows the tagged relative pointer
/// in its `Flags` field. See `swift_distributed_getFirstValidationRecord` in
/// `stdlib/public/Distributed/DistributedActor.cpp`.
@available(SwiftStdlib 6.5, *)
@_silgen_name("swift_distributed_getFirstValidationRecord")
internal func _swift_distributed_getFirstValidationRecord(
  _ targetNameStart: UnsafePointer<UInt8>,
  _ targetNameLength: UInt
) -> UnsafeRawPointer?

/// Decode a `RelativeDirectPointer` stored at `field`: a signed 32-bit byte
/// offset from the field's own address. `swift5_daval` records use these (as
/// the accessible-function records do) so they need no load-time relocations.
@available(SwiftStdlib 6.5, *)
@inline(__always)
internal func _relativePointer(
  at field: UnsafeRawPointer
) -> UnsafeRawPointer {
  let offset = unsafe Int(field.load(as: Int32.self))
  return unsafe field + offset
}

/// Materialize the validators in a target's `swift5_daval` linked list,
/// starting at `record` and following each record's `relativeNext` field
/// (offset 12; a self-relative offset of 0 ends the list). Recursion avoids a
/// mutable unsafe-pointer variable, which the strict-memory-safety checker
/// rejects.
@available(SwiftStdlib 6.5, *)
internal func _collectValidators(
  from record: UnsafeRawPointer,
  into collected: inout [RemoteCallValidator]
) {
  // Field `relativeAccessor` (offset 8) -> accessor storage -> C fn ptr.
  let accessor = unsafe _relativePointer(at: record.advanced(by: 8))
    .assumingMemoryBound(to: _DistributedValidationAccessor.self)
    .pointee

  // Materialize the validator via the accessor. The `type` argument is a
  // pointer to `RemoteCallValidator.self` - the accessor uses it as a
  // self-check to reject mismatches when multiple copies of the runtime are
  // loaded (currently unused; kept for ABI symmetry).
  var validator: RemoteCallValidator = RemoteCallValidator({ })
  var validatorType: Any.Type = RemoteCallValidator.self
  let ok = withUnsafeMutablePointer(to: &validator) { outPtr in
    withUnsafePointer(to: &validatorType) { typePtr in
      unsafe accessor(
        UnsafeMutableRawPointer(outPtr),
        UnsafeRawPointer(typePtr),
        nil,
        0)
    }
  }
  if ok { collected.append(validator) }

  // Field `relativeNext` (offset 12): 0 ends the list.
  let nextField = unsafe record.advanced(by: 12)
  let nextOffset = unsafe Int(nextField.load(as: Int32.self))
  if nextOffset != 0 {
    let next = unsafe nextField.advanced(by: nextOffset)
    unsafe _collectValidators(from: next, into: &collected)
  }
}

// ==== -----------------------------------------------------------------------
// MARK: Lookup + preflight

@available(SwiftStdlib 6.5, *)
extension DistributedValidation {

  /// Look up the composed ``RemoteCallValidator`` for the distributed target
  /// identified by `targetIdentifier` (its mangled distributed-thunk name,
  /// i.e. `RemoteCallTarget.identifier`). Returns `nil` if the target has no
  /// `@Entitlement`/`@ValidateRemoteCall`.
  ///
  /// The target's first validation record is found via its accessible-function
  /// record's tagged `Flags` pointer; further records for the same target
  /// (from stacked attributes, or the compiler's cross-module inheritance of a
  /// protocol requirement's attribute onto the witness) are chained via
  /// `relativeNext`. All of them compose as **AllOf**: every validator must
  /// accept before the call runs.
  ///
  /// The returned validator's `check()` invokes each collected validator in
  /// list order; the first thrown error propagates and short-circuits the
  /// rest. Only the AllOf outcome (accept iff every check accepts) is
  /// guaranteed; the specific record whose error surfaces first is not.
  public static func lookup(
    targetIdentifier: String
  ) -> RemoteCallValidator? {
    var utf8 = Array(targetIdentifier.utf8)
    let first: UnsafeRawPointer? = unsafe utf8.withUnsafeBufferPointer { buf in
      guard let base = unsafe buf.baseAddress else { return nil }
      return unsafe _swift_distributed_getFirstValidationRecord(
        base, UInt(buf.count))
    }
    guard let first = unsafe first else { return nil }

    // Materialize this target's validators by walking its `swift5_daval`
    // linked list (see `_collectValidators`).
    var collected: [RemoteCallValidator] = []
    unsafe _collectValidators(from: first, into: &collected)

    if collected.isEmpty { return nil }
    if collected.count == 1 { return collected[0] }
    // Bind to a `let` so the Sendable closure captures an immutable copy.
    let validators = collected
    return RemoteCallValidator {
      for validator in validators {
        try validator.check()
      }
    }
  }

  /// Preflight hook called from `DistributedActorSystem.executeDistributedTarget`
  /// before argument decoding. Looks up the composed validator for
  /// `target.identifier` and invokes `check()`. No-op if the target carries no
  /// validation.
  public static func preflight<Act: DistributedActor>(
    on actor: Act, target: RemoteCallTarget
  ) throws {
    guard let validator = lookup(targetIdentifier: target.identifier)
    else { return }

    try validator.check()
  }
}
