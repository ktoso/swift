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
//   - The ABI of records placed in the `swift5_daval` section by the
//     macros: `_DistributedValidationAccessor`, `_DistributedValidationRecord`,
//     `_DistributedValidationKind` FourCC.
//   - `RemoteCallValidator`: the receive-side value the accessor produces,
//     wrapping the closure the runtime ultimately invokes.
//   - `_DistributedValidation`: FNV-1a-64 hash + demangling helper + the
//     per-platform section walker + the `executeDistributedTarget` preflight
//     hook. Generic — parameterized only in `RemoteCallValidator`; no
//     entitlement-specific state or logic lives here.
//
// The record layout mirrors swift-testing's TestContentRecord verbatim so
// offline tooling can share parsing code across sections; only the FourCC
// in the first field differs. See:
//   ~/code/swift-testing/Documentation/ABI/TestContent.md
//
// Entitlement-specific pieces (`_EntitlementPolicy`, `_EntitlementCheckFailed`,
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

/// One record placed in the `swift5_daval` section by an @Entitlement or
/// @ValidateRemoteCall macro expansion. Field order matches swift-testing's
/// `TestContentRecord` verbatim: `reserved1: UInt32` sits between `kind` and
/// `accessor` to preserve natural alignment of the following pointer-sized
/// fields on 64-bit targets (no compiler-inserted padding, 32-byte stride).
///
/// The `accessor` field is a non-optional C function pointer. A record whose
/// `kind` field is `0` (`_DistributedValidationKind` reserved value) is
/// ignored by the runtime; there is therefore no need to make `accessor`
/// itself nullable, and doing so would preclude SE-0492 static
/// initialization (optionals are not permitted constant expressions).
public typealias _DistributedValidationRecord = (
  kind: UInt32,
  reserved1: UInt32,
  accessor: _DistributedValidationAccessor,
  context: UInt,
  reserved2: UInt
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
///           guard _DistributedValidation.currentEntitlements.contains("admin")
///           else { throw _EntitlementCheckFailed(missing: "admin") }
///         }
///       }
///
///       public static func requireEntitlement(_ name: String) -> RemoteCallValidator {
///         RemoteCallValidator {
///           guard _DistributedValidation.currentEntitlements.contains(name)
///           else { throw _EntitlementCheckFailed(missing: name) }
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
/// section, hashes identities, and materializes validation policies for a
/// given `(actorTypeID, methodID)` pair.
///
/// Policy-specific state and behavior — the entitlement task-local, the
/// policy evaluator — live as extensions in
/// `DistributedValidation+Entitlement.swift`.
///
/// The FNV-1a-64 hash function and the `swift5_daval` record layout are
/// **ABI-committed**: identical implementations run at macro-expansion time
/// (in the SwiftMacros plugin) and here at receive time. Changing either
/// without a coordinated update breaks the lookup.
@available(SwiftStdlib 6.5, *)
public enum _DistributedValidation {

  /// FNV-1a-64 of the UTF-8 bytes of a string. Must exactly match the
  /// `fnv1a64` helper in
  /// `lib/Macros/Sources/SwiftMacros/DistributedValidationMacros.swift`.
  @inlinable
  public static func fnv1a64(of string: String) -> UInt64 {
    var hash: UInt64 = 0xcbf29ce484222325 // FNV-1a-64 offset basis
    for byte in string.utf8 {
      hash ^= UInt64(byte)
      hash &*= 0x100000001b3          // FNV-1a-64 prime, wrapping multiply
    }
    return hash
  }
}

/// Extract a distributed target's simple func name from its mangled
/// identifier. E.g. `"$s4main7GreeterC5greetSSyF"` -> `"greet"`. Uses the
/// existing stdlib demangler `_getFunctionFullNameFromMangledName`, which
/// returns something like `"main.Greeter.greet()"`; we take the identifier
/// between the last `.` and the first `(`.
///
/// Returns `nil` if the identifier can't be demangled or doesn't look like
/// a function name.
@available(SwiftStdlib 6.5, *)
internal func _extractSimpleFuncName(fromMangled mangled: String) -> String? {
  guard let full = _getFunctionFullNameFromMangledName(mangledName: mangled)
  else { return nil }

  // Strip an argument list `(...)`, if present.
  let bareName: Substring
  if let paren = full.firstIndex(of: "(") {
    bareName = full[..<paren]
  } else {
    bareName = Substring(full)
  }
  // Take the identifier after the last `.` (module + type qualifier).
  if let dot = bareName.lastIndex(of: ".") {
    return String(bareName[bareName.index(after: dot)...])
  }
  return String(bareName)
}

// ==== -----------------------------------------------------------------------
// MARK: Section lookup + preflight

@available(SwiftStdlib 6.5, *)
extension _DistributedValidation {

  /// Look up the ``RemoteCallValidator`` attached to the given target on the
  /// given actor type. Returns `nil` if no matching record is registered in
  /// any loaded image (i.e. the target has no
  /// `@Entitlement`/`@ValidateRemoteCall`).
  ///
  /// The first matching record wins. Multiple records for the same
  /// `(actorTypeID, methodID)` can arise from stacked attributes; a future
  /// revision may evaluate all matches in source order rather than
  /// returning early.
  public static func lookup(
    actorTypeID: UInt64,
    methodID: UInt64
  ) -> RemoteCallValidator? {
#if canImport(Darwin)
    return _lookupMachO(actorTypeID: actorTypeID, methodID: methodID)
#else
    // TODO: ELF and COFF walkers are follow-ups. Returning nil means the
    // Distributed runtime treats the target as un-validated; no false
    // positives, no false negatives on the "no validation registered" case,
    // but any validated target passes through without a check on these
    // platforms until this is filled in.
    return nil
#endif
  }

  /// Preflight hook called from `DistributedActorSystem.executeDistributedTarget`
  /// before argument decoding. Extracts the simple func name from the
  /// mangled `target.identifier`, hashes `(actor type name, func name)` into
  /// `(actorTypeID, methodID)`, looks up the validator in the daval section,
  /// and invokes `check()`. No-op if no validation record is registered
  /// for the target.
  public static func preflight<Act: DistributedActor>(
    on actor: Act, target: RemoteCallTarget
  ) throws {
    guard let simpleName = _extractSimpleFuncName(fromMangled: target.identifier)
    else { return }

    let actorTypeID = fnv1a64(of: _typeName(Act.self, qualified: false))
    let methodID = fnv1a64(of: simpleName)

    guard let validator = lookup(actorTypeID: actorTypeID, methodID: methodID)
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
extension _DistributedValidation {

  /// Walk `__DATA_CONST,__swift5_daval` in every loaded image, invoking the
  /// accessor of the first record whose `context` (actorTypeID) and
  /// `reserved2` (methodID) fields match.
  ///
  /// Not registered for `_dyld_register_func_for_add_image`: this is a
  /// per-call linear scan for the first cut. A cache keyed by
  /// `(actorTypeID, methodID)` and populated from an image-load callback is
  /// a follow-up performance change.
  fileprivate static func _lookupMachO(
    actorTypeID: UInt64,
    methodID: UInt64
  ) -> RemoteCallValidator? {
    let imageCount = _dyld_image_count()
    for imageIndex in 0..<imageCount {
      guard let mh = unsafe _dyld_get_image_header(imageIndex) else { continue }
      guard let validator = unsafe _lookupInImage(
        mh: mh,
        actorTypeID: actorTypeID,
        methodID: methodID)
      else { continue }
      return validator
    }
    return nil
  }

  /// Search one image's `__swift5_daval` section for a matching record.
  private static func _lookupInImage(
    mh: UnsafeRawPointer,
    actorTypeID: UInt64,
    methodID: UInt64
  ) -> RemoteCallValidator? {
    // Skip images in the shared cache. System libraries never register
    // records and walking them is expensive.
    let flags = unsafe mh.load(fromByteOffset: _machHeader64FlagsOffset,
                               as: UInt32.self)
    guard 0 == (flags & _MH_DYLIB_IN_CACHE) else { return nil }

    var size: UInt = 0
    let start: UnsafeRawPointer? = "__swift5_daval".withCString { sectname in
      "__DATA_CONST".withCString { segname in
        unsafe _getsectiondata(mh, segname, sectname, &size)
      }
    }
    guard let start = unsafe start, size > 0 else { return nil }

    let stride = unsafe MemoryLayout<_DistributedValidationRecord>.stride
    let count = Int(size) / stride

    for i in 0..<count {
      let recordPtr = unsafe start.advanced(by: i * stride)
        .assumingMemoryBound(to: _DistributedValidationRecord.self)
      let record = unsafe recordPtr.pointee

      guard unsafe record.kind == _DistributedValidationKind.validation.rawValue,
            unsafe UInt64(record.context) == actorTypeID,
            unsafe UInt64(record.reserved2) == methodID
      else { continue }

      // Materialize the validator via the accessor. The `type` argument is a
      // pointer to `RemoteCallValidator.self` — the accessor uses it as a
      // self-check to reject mismatches when multiple copies of the runtime
      // are loaded (currently unused; kept for ABI symmetry).
      var validator: RemoteCallValidator = RemoteCallValidator({ })
      var validatorType: Any.Type = RemoteCallValidator.self
      let ok = withUnsafeMutablePointer(to: &validator) { outPtr in
        withUnsafePointer(to: &validatorType) { typePtr in
          unsafe record.accessor(
            UnsafeMutableRawPointer(outPtr),
            UnsafeRawPointer(typePtr),
            nil,
            0)
        }
      }
      if ok { return validator }
    }
    return nil
  }
}

#endif
