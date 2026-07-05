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
//     `_DistributedValidationKind` FourCC. These record-shape typealiases
//     stay underscored because they name the wire ABI of the section, not
//     user-facing API.
//   - `RemoteCallValidator`: the receive-side value the accessor produces,
//     wrapping the closure the runtime ultimately invokes.
//   - `DistributedValidation`: the per-platform section walker + the
//     `executeDistributedTarget` preflight hook. Generic - parameterized only
//     in `RemoteCallValidator`; no entitlement-specific state or logic lives
//     here.
//
// A record identifies its target by the target's full mangled distributed-
// thunk name, which it relative-points at. That string is the SAME one the
// target's accessible-function record carries (emitted once by IRGen), and it
// is exactly the `RemoteCallTarget.identifier` the receive side already holds.
// So lookup is a byte-for-byte name match - collision-free (full mangled name,
// not a simple-name hash) with no string stored twice.
//
// The record layout follows the same relative-pointer shape as the
// accessible-function record; only the FourCC in the first field and the
// section differ. See ~/code/swift-testing/Documentation/ABI/TestContent.md
// for the related offline-tooling record pattern.
//
// Entitlement-specific pieces (`EntitlementPolicy`, `EntitlementCheckFailed`,
// the receive-side task-local entitlement set, the entitlement evaluator)
// live in `DistributedValidation+Entitlement.swift`.
//
//===----------------------------------------------------------------------===//

import Swift

// ==== -----------------------------------------------------------------------
// MARK: Record layout

/// The C function pointer stored in a `_DistributedValidationRecord`. When
/// invoked by the Distributed runtime it must materialize a value describing
/// the validation policy for the record's target into `outValue`, and return
/// `true`. If it cannot (e.g. the `type` argument does not match), it must
/// leave `outValue` uninitialized and return `false`.
public typealias _DistributedValidationAccessor = @convention(c) (
  _ outValue: UnsafeMutableRawPointer,
  _ type: UnsafeRawPointer,
  _ hint: UnsafeRawPointer?,
  _ reserved: UInt
) -> CBool

/// One record placed in the `swift5_daval` section by the compiler (IRGen),
/// next to the target's accessible-function record. The compiler emits the
/// record - not the macro - because two of its fields are relative pointers,
/// which a `@section` constant cannot express, and because the identity is the
/// target's full mangled distributed-thunk name, which the macro cannot see.
///
/// Fields (all 4 bytes; total stride 32-bit-uniform 16 bytes):
///   - `kind`: `_DistributedValidationKind` FourCC. A record whose kind is not
///     `.validation` is ignored.
///   - `flags`: reserved (currently 0).
///   - `relativeName`: a `RelativeDirectPointer<CChar>` to the target's mangled
///     distributed-thunk name - the SAME string the accessible-function record
///     carries, and equal to `RemoteCallTarget.identifier`.
///   - `relativeAccessor`: a `RelativeDirectPointer` to the macro-emitted
///     `_DistributedValidationAccessor` global (in `swift5_davala`). Loading
///     through it yields the C function pointer to invoke.
///
/// The two relative pointers are signed byte offsets from the address of their
/// own field (see `_relativePointer`). They are decoded manually because Swift
/// cannot express `RelativeDirectPointer` as a stored tuple element.
public typealias _DistributedValidationRecord = (
  kind: UInt32,
  flags: UInt32,
  relativeName: Int32,
  relativeAccessor: Int32
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

/// Namespace for runtime-side machinery that walks the `swift5_daval`
/// section and materializes validation policies for a given distributed
/// target, identified by its mangled distributed-thunk name
/// (`RemoteCallTarget.identifier`).
///
/// Policy-specific state and behavior - the entitlement task-local, the
/// policy evaluator - live as extensions in
/// `DistributedValidation+Entitlement.swift`.
///
/// The `swift5_daval` record layout is **ABI-committed**: the compiler emits
/// records here and this walker reads them; the two must agree.
@available(SwiftStdlib 6.5, *)
public enum DistributedValidation {}

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

// ==== -----------------------------------------------------------------------
// MARK: Section lookup + preflight

@available(SwiftStdlib 6.5, *)
extension DistributedValidation {

  /// Look up the composed ``RemoteCallValidator`` for the distributed target
  /// identified by `targetIdentifier` (its mangled distributed-thunk name,
  /// i.e. `RemoteCallTarget.identifier`). Returns `nil` if no matching record
  /// is registered in any loaded image (i.e. the target has no
  /// `@Entitlement`/`@ValidateRemoteCall`).
  ///
  /// Multiple records for the same target arise from stacked attributes on the
  /// same distributed member, and from the compiler's cross-module inheritance
  /// of a protocol requirement's attribute onto the conforming actor's witness
  /// (the witness ends up with both its own attribute and the inherited one).
  /// All matching records compose as **AllOf**: every validator must accept
  /// before the call runs.
  ///
  /// The returned validator's `check()` invokes each collected validator in
  /// section-scan order; the first thrown error propagates and short-
  /// circuits the rest. Two images contributing records for the same target
  /// have unspecified inter-image order, so the specific record whose error
  /// surfaces first is not guaranteed to be stable across platforms - but
  /// the AllOf outcome (accept iff every check accepts) is.
  public static func lookup(
    targetIdentifier: String
  ) -> RemoteCallValidator? {
    var collected: [RemoteCallValidator] = []
#if canImport(Darwin)
    _collectMachO(targetIdentifier: targetIdentifier, into: &collected)
#elseif os(Linux) || os(FreeBSD) || os(Android) || arch(wasm32)
    _collectELF(targetIdentifier: targetIdentifier, into: &collected)
#elseif os(Windows)
    _collectCOFF(targetIdentifier: targetIdentifier, into: &collected)
#else
    // Platform with no known section-walking strategy. Leaving `collected`
    // empty means the Distributed runtime treats the target as un-validated:
    // no false positives, no false negatives on the "no validation
    // registered" case, but any validated target passes through without a
    // check.
#endif
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
  /// `target.identifier` in the `swift5_daval` section and invokes `check()`.
  /// No-op if no validation record is registered for the target.
  public static func preflight<Act: DistributedActor>(
    on actor: Act, target: RemoteCallTarget
  ) throws {
    guard let validator = lookup(targetIdentifier: target.identifier)
    else { return }

    try validator.check()
  }
}

#if canImport(Darwin)

// ==== -----------------------------------------------------------------------
// MARK: Mach-O section walker (Darwin only)

// Bindings to the Mach-O runtime APIs we need. Declared via @_silgen_name so
// the Distributed stdlib doesn't have to pull in the full `Darwin.MachO`
// submodule (which is fine on macOS proper but complicates the module's
// dependency graph on other Darwin variants).

/// Number of loaded Mach images in the current process.
@_silgen_name("_dyld_image_count")
private func _dyld_image_count() -> UInt32

/// Base address of the Mach header of the i-th loaded image (`nil` if none).
@_silgen_name("_dyld_get_image_header")
private func _dyld_get_image_header(_ imageIndex: UInt32) -> UnsafeRawPointer?

/// Retrieves the address and size of the named section in the given image.
/// Returns `nil` if the section is absent. Writes the section's size to
/// `*sizePtr` on success.
@_silgen_name("getsectiondata")
private func _getsectiondata(
  _ mh: UnsafeRawPointer,
  _ segname: UnsafePointer<CChar>,
  _ sectname: UnsafePointer<CChar>,
  _ sizePtr: UnsafeMutablePointer<UInt>
) -> UnsafeRawPointer?

/// Mach-O `mach_header_64.flags` bit set when an image is in the shared
/// dyld cache. We skip such images because system dylibs never register
/// distributed-validation records.
private let _MH_DYLIB_IN_CACHE: UInt32 = 0x80000000

/// Bytes at offset 24 of a `mach_header_64` are its `flags` field. We access
/// the whole header through a raw pointer to avoid a Mach-O header import.
private let _machHeader64FlagsOffset = 24

@available(SwiftStdlib 6.5, *)
extension DistributedValidation {

  /// Walk `__DATA_CONST,__swift5_daval` in every loaded image, appending a
  /// `RemoteCallValidator` for every record whose name matches
  /// `targetIdentifier`.
  ///
  /// Not registered for `_dyld_register_func_for_add_image`: this is a
  /// per-call linear scan for the first cut. A cache keyed by the target
  /// identifier and populated from an image-load callback is a follow-up
  /// performance change.
  fileprivate static func _collectMachO(
    targetIdentifier: String,
    into collected: inout [RemoteCallValidator]
  ) {
    let imageCount = _dyld_image_count()
    for imageIndex in 0..<imageCount {
      guard let mh = unsafe _dyld_get_image_header(imageIndex) else { continue }
      unsafe _collectInImage(
        mh: mh,
        targetIdentifier: targetIdentifier,
        into: &collected)
    }
  }

  /// Search one image's `__swift5_daval` section for matching records and
  /// append each materialized validator to `collected`.
  private static func _collectInImage(
    mh: UnsafeRawPointer,
    targetIdentifier: String,
    into collected: inout [RemoteCallValidator]
  ) {
    // Skip images in the shared cache. System libraries never register
    // records and walking them is expensive.
    let flags = unsafe mh.load(fromByteOffset: _machHeader64FlagsOffset,
                               as: UInt32.self)
    guard 0 == (flags & _MH_DYLIB_IN_CACHE) else { return }

    var size: UInt = 0
    let start: UnsafeRawPointer? = "__swift5_daval".withCString { sectname in
      "__DATA_CONST".withCString { segname in
        unsafe _getsectiondata(mh, segname, sectname, &size)
      }
    }
    guard let start = unsafe start, size > 0 else { return }

    unsafe _scanValidationSection(
      start: start, byteCount: Int(size),
      targetIdentifier: targetIdentifier,
      into: &collected)
  }
}

#endif

// ==== -----------------------------------------------------------------------
// MARK: ELF / Wasm section walker

#if os(Linux) || os(FreeBSD) || os(Android) || arch(wasm32)

// Linker-emitted sentinels bracketing the `swift5_daval` section within the
// current image. `__start_<section>` and `__stop_<section>` are auto-generated
// by GNU-style linkers for sections whose names are valid C identifiers, which
// `swift5_daval` is. This gives us the section bounds without needing an
// image-list walk API or a stdlib-runtime API extension (unlike
// `swift_enumerateAllMetadataSections`, which requires plumbing through
// SwiftShims).
//
// Trade-off: this covers only records emitted into the current image. Records
// emitted from dynamically-loaded libraries (dlopen'd, or linked into other
// shared objects) are not visible via these sentinels; a future revision can
// switch to `dl_iterate_phdr` or the SwiftShims metadata-section enumeration
// once cross-image lookup is needed. For a v1 where the distributed actor and
// its `@Entitlement` records are typically in the same image, this suffices.
@_silgen_name("__start_swift5_daval")
private var _swift5_daval_start: UInt8

@_silgen_name("__stop_swift5_daval")
private var _swift5_daval_stop: UInt8

@available(SwiftStdlib 6.5, *)
extension DistributedValidation {
  fileprivate static func _collectELF(
    targetIdentifier: String,
    into collected: inout [RemoteCallValidator]
  ) {
    let start = unsafe withUnsafePointer(to: &_swift5_daval_start) {
      UnsafeRawPointer($0)
    }
    let stop = unsafe withUnsafePointer(to: &_swift5_daval_stop) {
      UnsafeRawPointer($0)
    }
    let byteCount = unsafe stop - start
    unsafe _scanValidationSection(
      start: start, byteCount: byteCount,
      targetIdentifier: targetIdentifier,
      into: &collected)
  }
}

#endif

// ==== -----------------------------------------------------------------------
// MARK: COFF section walker (Windows)

#if os(Windows)

// COFF bracket sentinels: `.sw5daval$A` and `.sw5daval$Z` sandwich the payload
// records in `.sw5daval$B` so the linker collates them into a contiguous
// range. Same pattern as `.sw5prt$A/$B/$Z` in `SwiftRT-COFF.cpp`.
//
// TODO: this only sees the current image's records. Cross-DLL lookup on
// Windows requires walking `HMODULE`s (see swift-testing's
// `SectionBounds.swift` Windows implementation) and is deferred.

@_silgen_name(".sw5daval$A")
private var _swift5_daval_start_win: UInt8

@_silgen_name(".sw5daval$Z")
private var _swift5_daval_stop_win: UInt8

@available(SwiftStdlib 6.5, *)
extension DistributedValidation {
  fileprivate static func _collectCOFF(
    targetIdentifier: String,
    into collected: inout [RemoteCallValidator]
  ) {
    let start = unsafe withUnsafePointer(to: &_swift5_daval_start_win) {
      UnsafeRawPointer($0)
    }
    let stop = unsafe withUnsafePointer(to: &_swift5_daval_stop_win) {
      UnsafeRawPointer($0)
    }
    let byteCount = unsafe stop - start
    unsafe _scanValidationSection(
      start: start, byteCount: byteCount,
      targetIdentifier: targetIdentifier,
      into: &collected)
  }
}

#endif

// ==== -----------------------------------------------------------------------
// MARK: Shared section-scanning helper

#if canImport(Darwin) || os(Linux) || os(FreeBSD) || os(Android) || arch(wasm32) || os(Windows)

/// Iterate the `_DistributedValidationRecord` stride-array packed in
/// `[start, start + byteCount)` and append a materialized
/// `RemoteCallValidator` to `collected` for every record whose name (decoded
/// from its `relativeName` field) equals `targetIdentifier`.
///
/// All platform walkers share this; they differ only in how they compute the
/// section's bounds. The two pointer fields are `RelativeDirectPointer`s
/// (signed 32-bit self-relative offsets) so the records carry no load-time
/// relocations; they are decoded via `_relativePointer`.
@available(SwiftStdlib 6.5, *)
private func _scanValidationSection(
  start: UnsafeRawPointer,
  byteCount: Int,
  targetIdentifier: String,
  into collected: inout [RemoteCallValidator]
) {
  guard byteCount > 0 else { return }
  let stride = unsafe MemoryLayout<_DistributedValidationRecord>.stride
  let count = byteCount / stride

  for i in 0..<count {
    let recordPtr = unsafe start.advanced(by: i * stride)

    // Field `kind` (offset 0).
    let kind = unsafe recordPtr.load(as: UInt32.self)
    guard kind == _DistributedValidationKind.validation.rawValue else { continue }

    // Field `relativeName` (offset 8): the target's mangled distributed-thunk
    // name. This is the same string the accessible-function record carries and
    // equals `RemoteCallTarget.identifier`, so a byte match is a precise,
    // collision-free identity check.
    let nameField = unsafe recordPtr + 8
    let namePtr = unsafe _relativePointer(at: nameField)
      .assumingMemoryBound(to: CChar.self)
    let recordedName = unsafe String(cString: namePtr)
    guard recordedName == targetIdentifier else { continue }

    // Field `relativeAccessor` (offset 12): points at the macro-emitted
    // accessor global; load through it for the C function pointer.
    let accField = unsafe recordPtr + 12
    let accessor = unsafe _relativePointer(at: accField)
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
  }
}

#endif
