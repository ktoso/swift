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
//   - `DistributedValidation`: internal-only helpers. `lookup(...)` (internal)
//     resolves and composes a target's validators; `RemoteCallValidationLookupError`
//     is thrown when a target has records but none are bound to the requesting
//     actor system. The developer-facing entry point is `self.validate(target:context:)`
//     on `DistributedActorSystem` (see the extension in `DistributedActorSystem.swift`).
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
/// `RemoteCallValidator` is parameterized on the concrete
/// ``DistributedActorSystem`` so its stored closure can accept that system's
/// ``DistributedActorSystem/RemoteCallValidationContext`` and throw its
/// ``DistributedActorSystem/RemoteCallValidationFailure``.
///
/// Extend it with static factory members (usually constrained to a specific
/// actor system) so they can be referenced via implicit-member syntax at a
/// `@ValidateRemoteCall(.someFactory)` site:
///
///     extension RemoteCallValidator where ActorSystem == MySystem {
///       public static var requireAdminRole: RemoteCallValidator {
///         RemoteCallValidator { _ in
///           guard DistributedValidation.currentEntitlements.contains("admin")
///           else { throw EntitlementCheckFailed(missing: "admin") }
///         }
///       }
///
///       public static func requireEntitlement(_ name: String) -> RemoteCallValidator {
///         RemoteCallValidator { _ in
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
public struct RemoteCallValidator<ActorSystem: DistributedActorSystem>: Sendable {
  @usableFromInline
  internal let _check: @Sendable (ActorSystem.RemoteCallValidationContext) throws(ActorSystem.RemoteCallValidationFailure) -> Void

  /// Wraps a validator closure or top-level function reference. The closure
  /// receives this actor system's ``DistributedActorSystem/RemoteCallValidationContext``
  /// and may throw its ``DistributedActorSystem/RemoteCallValidationFailure``
  /// to reject the call.
  public init(
    _ check: @escaping @Sendable (ActorSystem.RemoteCallValidationContext) throws(ActorSystem.RemoteCallValidationFailure) -> Void
  ) {
    self._check = check
  }

  /// Pass-through initializer. Enables the macro plugin's emission to
  /// funnel both `@ValidateRemoteCall({ ... })` and
  /// `@ValidateRemoteCall(.namedRecipe)` through a single code path.
  public init(_ validator: RemoteCallValidator<ActorSystem>) {
    self._check = validator._check
  }

  /// Invoke the wrapped validator against `context`. Rethrows whatever the
  /// validator body throws.
  public func check(
    context: ActorSystem.RemoteCallValidationContext
  ) throws(ActorSystem.RemoteCallValidationFailure) {
    try self._check(context)
  }
}

// ==== -----------------------------------------------------------------------
// MARK: Opt-in validation-macro inheritance

/// Marker protocol for the per-macro types that identify a receive-side
/// validation macro (`@Entitlement`, `@ValidateRemoteCall`, or one defined in
/// an external module). A distributed actor system opts into inheriting a
/// validation macro from protocol requirements onto its actors' witnesses by
/// listing the macro's marker type in
/// `DistributedRemoteCallValidation.InheritMacros<...>`.
///
/// The marker type is generated by `@DistributedValidatorMacro` attached to
/// the macro declaration and is named `<MacroName>Macro` (e.g. the marker for
/// `@Entitlement` is `EntitlementMacro`). The compiler recovers the macro
/// identity by stripping the `Macro` suffix.
@available(SwiftStdlib 6.5, *)
public protocol DistributedRemoteCallValidationMacroIdentifier {}

/// Namespace for the actor-system opt-in that selects which validation macros
/// are inherited onto witnesses.
@available(SwiftStdlib 6.5, *)
public enum DistributedRemoteCallValidation {
  /// Lists the validation-macro marker types an actor system inherits. An
  /// empty list inherits nothing; the compiler reads each marker type's name
  /// (stripping the `Macro` suffix) to decide which requirement attributes to
  /// clone onto witnesses.
  @available(SwiftStdlib 6.5, *)
  public struct InheritMacros<each Macro: DistributedRemoteCallValidationMacroIdentifier>: DistributedRemoteCallValidationSetting {}
}

@available(SwiftStdlib 6.5, *)
public protocol DistributedRemoteCallValidationSetting {}

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
///
/// Each record's accessor is offered a pointer to `RemoteCallValidator<ActorSystem>.self`;
/// if the accessor was emitted for a different actor system it will refuse
/// (returning `false`), and we record that so the caller can distinguish "no
/// records at all" from "records exist but not for me". A single target with
/// mixed-actor-system records (unusual but possible if third-party code
/// composed them) is tolerated: matches are collected, mismatches are silently
/// skipped, and `sawMatch` stays `true` overall.
@available(SwiftStdlib 6.5, *)
internal func _collectValidators<ActorSystem: DistributedActorSystem>(
  from record: UnsafeRawPointer,
  using system: ActorSystem.Type,
  into collected: inout [RemoteCallValidator<ActorSystem>]
) -> (sawMismatch: Bool, sawMatch: Bool) {
  // Field `relativeAccessor` (offset 8) -> accessor storage -> C fn ptr.
  let accessor = unsafe _relativePointer(at: record.advanced(by: 8))
    .assumingMemoryBound(to: _DistributedValidationAccessor.self)
    .pointee

  // Materialize the validator via the accessor. The `type` argument is a
  // pointer to `RemoteCallValidator<ActorSystem>.self`; the accessor uses it
  // as an actor-system cross-check and returns `false` if this record was
  // emitted for a different `DistributedActorSystem`.
  var sawMismatch = false
  var sawMatch = false
  let size = MemoryLayout<RemoteCallValidator<ActorSystem>>.size
  let align = MemoryLayout<RemoteCallValidator<ActorSystem>>.alignment
  unsafe withUnsafeTemporaryAllocation(byteCount: size, alignment: align) { buf in
    guard let outPtr = unsafe buf.baseAddress else { return }
    var validatorType: Any.Type = RemoteCallValidator<ActorSystem>.self
    let ok = unsafe withUnsafePointer(to: &validatorType) { typePtr in
      unsafe accessor(outPtr, UnsafeRawPointer(typePtr), nil, 0)
    }
    if ok {
      let v = unsafe outPtr
        .assumingMemoryBound(to: RemoteCallValidator<ActorSystem>.self).move()
      collected.append(v)
      sawMatch = true
    } else {
      sawMismatch = true
    }
  }

  // Field `relativeNext` (offset 12): 0 ends the list.
  let nextField = unsafe record.advanced(by: 12)
  let nextOffset = unsafe Int(nextField.load(as: Int32.self))
  if nextOffset != 0 {
    let next = unsafe nextField.advanced(by: nextOffset)
    let tail = unsafe _collectValidators(from: next, using: ActorSystem.self,
                                         into: &collected)
    sawMismatch = sawMismatch || tail.sawMismatch
    sawMatch = sawMatch || tail.sawMatch
  }
  return (sawMismatch, sawMatch)
}

// ==== -----------------------------------------------------------------------
// MARK: Lookup

/// Errors raised by ``DistributedValidation/lookup(targetIdentifier:using:)``.
///
/// A target with no validation records is NOT an error - `lookup` returns
/// `nil` in that case. `RemoteCallValidationLookupError` covers lookup-time
/// failures that are distinct from a validator's own rejection.
@available(SwiftStdlib 6.5, *)
public enum RemoteCallValidationLookupError: Error, CustomStringConvertible {
  /// The target has one or more `swift5_daval` validation records, but none
  /// of them were emitted for the actor system the caller asked about. This
  /// is a programmer error: the target belongs to a different
  /// ``DistributedActorSystem`` than the one running the validation.
  ///
  /// - Parameters:
  ///   - targetIdentifier: the mangled distributed-thunk identifier of the
  ///     target that was looked up.
  ///   - requestedSystem: the actor system the caller passed to the lookup.
  case actorSystemTypeMismatch(targetIdentifier: String, requestedSystem: Any.Type)

  public var description: String {
    switch self {
    case .actorSystemTypeMismatch(let id, let system):
      return "Remote-call validation records exist for '\(id)' but none are " +
        "bound to '\(system)'. The target likely belongs to a different " +
        "DistributedActorSystem."
    }
  }
}

@available(SwiftStdlib 6.5, *)
extension DistributedValidation {

  /// Look up the composed ``RemoteCallValidator`` for the distributed target
  /// identified by `targetIdentifier` (its mangled distributed-thunk name,
  /// i.e. `RemoteCallTarget.identifier`) under actor system `ActorSystem`.
  ///
  /// - Returns `nil` if the target carries no validation records at all.
  /// - Throws ``RemoteCallValidationLookupError/actorSystemTypeMismatch(targetIdentifier:requestedSystem:)``
  ///   if the target carries records but none of them were emitted for
  ///   `ActorSystem`.
  /// - Otherwise returns an AllOf composition of the collected validators:
  ///   invoking `.check(context:)` runs each validator in list order and the
  ///   first thrown error short-circuits the rest.
  ///
  /// The target's first validation record is found via its accessible-function
  /// record's tagged `Flags` pointer; further records for the same target
  /// (from stacked attributes, or the compiler's cross-module inheritance of a
  /// protocol requirement's attribute onto the witness) are chained via
  /// `relativeNext`.
  ///
  /// Reached from ``DistributedActorSystem/validate(target:context:)``, which
  /// is what actor-system implementations call.
  internal static func lookup<ActorSystem: DistributedActorSystem>(
    targetIdentifier: String,
    using system: ActorSystem.Type
  ) throws(RemoteCallValidationLookupError) -> RemoteCallValidator<ActorSystem>? {
    var utf8 = Array(targetIdentifier.utf8)
    let firstRecord: UnsafeRawPointer? = unsafe utf8.withUnsafeBufferPointer { buf in
      guard let base = unsafe buf.baseAddress else { return nil }
      return unsafe _swift_distributed_getFirstValidationRecord(
        base, UInt(buf.count))
    }
    guard let first = unsafe firstRecord else {
      return nil // no records
    }

    // Collect this target's validators by walking its `swift5_daval`
    // linked list (see `_collectValidators`).
    var collected: [RemoteCallValidator<ActorSystem>] = []
    let (sawMismatch, sawMatch) = unsafe _collectValidators(
      from: first, using: ActorSystem.self, into: &collected)

    if !sawMatch && sawMismatch {
      // Records exist for this target but not one belongs to `ActorSystem`.
      throw .actorSystemTypeMismatch(
        targetIdentifier: targetIdentifier,
        requestedSystem: ActorSystem.self)
    }

    guard collected.count > 1 else {
      return collected.first // a single validator, or nil, which is fine as well
    }

    // Bind to a `let` so the Sendable closure captures an immutable copy.
    let validators = collected
    let allOf: @Sendable (ActorSystem.RemoteCallValidationContext)
      throws(ActorSystem.RemoteCallValidationFailure) -> Void = { context throws(ActorSystem.RemoteCallValidationFailure) in
        for validator in validators {
          try validator.check(context: context)
        }
      }
    return RemoteCallValidator<ActorSystem>(allOf)
  }
}
