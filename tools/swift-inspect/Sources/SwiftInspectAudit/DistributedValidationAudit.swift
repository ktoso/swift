//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

// Platform-neutral offline decoder for the distributed remote-call
// validation ABI emitted by the compiler. On each object format the
// sections are named differently and file/VM math differs (skew is
// resolved by the backend), but the ABI shape is identical:
//
//   accessible-function record:
//     RelativeDirectPointer<const char> Name          (i32)
//     RelativeDirectPointer<...>        GenericEnv    (i32, nullable)
//     RelativeDirectPointer<const char> FunctionType  (i32)
//     RelativeDirectPointer<void*>      Function      (i32)
//     AccessibleFunctionFlags           Flags         (i32) - tagged relative
//                                                       pointer to first daval
//                                                       record when bit 1 set
//
//   daval record:
//     { i32 kind='dval', i32 reserved, i32 relAccessor, i32 relNext }
//
//   accessor (in davala): closure implementing _DistributedValidationAccessor
//   description peer (in cstring): NUL-terminated UTF-8 policy text; symbol
//     name is the accessor's mangled name with `_desc` woven in via
//     `context.makeUniqueName`.
//
// See lib/IRGen/GenDecl.cpp:emitAccessibleFunction and
// stdlib/public/Distributed/DistributedValidation.swift for the emit and
// receive sides.

import Foundation

// ==== ---------------------------------------------------------------------
// MARK: Public output

/// One validator attached to a distributed method, as observed offline.
public struct DistributedValidator: Equatable {
  /// Name of the symbol holding the validation-accessor closure. `nil` if
  /// the local symbol was stripped from the binary.
  public var accessorSymbol: String?
  /// Human-readable source form of the policy the compiler recorded next
  /// to this accessor, e.g. `#"@Entitlement("com.example.transfer")"#`.
  /// `nil` when the compiler did not emit a description peer (either the
  /// binary predates this feature, or was built with
  /// `SWIFT_DISTRIBUTED_VALIDATE_RETAIN_DESCRIPTION_IN_BINARY=0`).
  public var policyText: String?

  public init(accessorSymbol: String?, policyText: String?) {
    self.accessorSymbol = accessorSymbol
    self.policyText = policyText
  }
}

/// One accessible-function record and any validators attached to it.
public struct DistributedAuditEntry: Equatable {
  public var mangledName: String
  public var isDistributed: Bool
  public var hasValidation: Bool
  public var validators: [DistributedValidator]

  public init(mangledName: String, isDistributed: Bool,
              hasValidation: Bool, validators: [DistributedValidator]) {
    self.mangledName = mangledName
    self.isDistributed = isDistributed
    self.hasValidation = hasValidation
    self.validators = validators
  }
}

public enum DistributedAuditError: Error, CustomStringConvertible {
  case skewMismatch(a: String, b: String)
  case acfuncsSizeNotMultiple(size: Int, recordSize: Int)
  case truncatedRecord(index: Int, field: String)
  case nullNamePointer(index: Int)
  case unreadableName(index: Int, offset: Int)
  case hasValidationWithoutDavalSection(record: String)
  case unknownDavalKind(record: String, kind: UInt32)
  case nullAccessorPointer(record: String)
  case truncatedDaval(record: String, field: String)
  case runawayDavalList(record: String, walked: Int)

  public var description: String {
    switch self {
    case .skewMismatch(let a, let b):
      return "sections have inconsistent VM/file skew: \(a) vs \(b); " +
             "offline audit cannot resolve relative pointers safely."
    case .acfuncsSizeNotMultiple(let size, let recordSize):
      return "accessible-functions section size (\(size)) is not a multiple of \(recordSize)"
    case .truncatedRecord(let i, let f):
      return "record #\(i): truncated \(f)"
    case .nullNamePointer(let i):
      return "record #\(i): null Name relative pointer"
    case .unreadableName(let i, let off):
      return "record #\(i): could not read Name string at file offset \(off)"
    case .hasValidationWithoutDavalSection(let r):
      return "record for \(r) has HasValidation set but the daval section is absent"
    case .unknownDavalKind(let r, let k):
      return "daval record for \(r): unknown kind 0x\(String(k, radix: 16))"
    case .nullAccessorPointer(let r):
      return "daval record for \(r): null relAccessor"
    case .truncatedDaval(let r, let f):
      return "daval record for \(r): truncated \(f)"
    case .runawayDavalList(let r, let walked):
      return "daval record list for \(r): exceeded safety limit after \(walked) entries"
    }
  }
}

// ==== ---------------------------------------------------------------------
// MARK: ABI constants

public enum DistributedAuditABI {
  /// TargetAccessibleFunctionRecord = 4 relative pointers + i32 Flags.
  public static let accessibleFunctionRecordSize = 20
  /// Byte offset of the Flags field within the accessible-function record.
  public static let flagsFieldOffset = 16
  /// AccessibleFunctionFlags: bit 0 is `Distributed`.
  public static let flagIsDistributed: UInt32 = 0x1
  /// AccessibleFunctionFlags: bit 1 is `HasValidation`.
  public static let flagHasValidation: UInt32 = 0x2
  /// Low bits used as tag on the Flags-as-relative-pointer trick.
  public static let flagTagMask: UInt32 = 0x3
  /// `_DistributedValidationKind.validation.rawValue` -- FourCC 'dval'.
  public static let davalKindValidation: UInt32 = 0x6476616c
  /// Daval record = { i32 kind, i32 reserved, i32 relAccessor, i32 relNext }.
  public static let davalRecordSize = 16
  public static let davalAccessorFieldOffset = 8
  public static let davalNextFieldOffset = 12
  /// Guardrail on the linked-list walker so a corrupted binary cannot
  /// stall the tool with a self-referential cycle.
  public static let davalListMaxLength = 1024
}

// ==== ---------------------------------------------------------------------
// MARK: Backend protocol

/// A section resolved to a file slice.
public struct AuditSection: Equatable {
  /// Human-readable label used only in diagnostics (e.g.
  /// `"__TEXT,__swift5_acfuncs"` or `"swift5_accessible_functions"`).
  public var label: String
  /// Byte offset from the start of the mapped file.
  public var fileOffset: Int
  /// Runtime virtual address the linker will map this section to.
  public var vmAddress: UInt64
  /// Size in bytes.
  public var size: Int

  public init(label: String, fileOffset: Int, vmAddress: UInt64, size: Int) {
    self.label = label
    self.fileOffset = fileOffset
    self.vmAddress = vmAddress
    self.size = size
  }
}

/// A per-object-format image the audit algorithm reads through. Backend
/// implementations resolve section names, symbol tables, and file bytes;
/// the walker itself is format-neutral.
public protocol AuditImageReader {
  /// A human-readable path/URL for diagnostics.
  var pathLabel: String { get }

  /// The `__TEXT,__swift5_acfuncs` (Mach-O) / `swift5_accessible_functions`
  /// (ELF) / `.sw5acfn$B` (COFF) section, or `nil` if the binary carries
  /// no accessible-function records.
  func accessibleFunctionsSection() -> AuditSection?

  /// The `__DATA_CONST,__swift5_daval` / `swift5_daval` / `.sw5daval$B`
  /// section, or `nil` if none is emitted (implies no validators).
  func davalSection() -> AuditSection?

  /// The section the compiler placed policy-description peers in
  /// (Mach-O: `__TEXT,__cstring`; ELF/Wasm: `swift5_davala_desc`;
  /// COFF: `.sw5davala_desc$B`). May be `nil`.
  func descriptionSection() -> AuditSection?

  /// Read a NUL-terminated UTF-8 string at a byte offset in the mapped file.
  func readCString(atFileOffset off: Int) -> String?

  /// Read a little-endian signed 32-bit integer at a byte offset.
  func readInt32(atFileOffset off: Int) -> Int32?

  /// Read a little-endian unsigned 32-bit integer at a byte offset.
  func readUInt32(atFileOffset off: Int) -> UInt32?

  /// Reverse-lookup: which symbol lives at this VM address? Keyed by the
  /// value in the binary's symbol table (`nlist_64.n_value` on Mach-O,
  /// `Elf64_Sym.st_value` on ELF), not the file offset.
  func symbolName(atVMAddress vm: UInt64) -> String?

  /// Iterate every symbol name plus its VM address. Used to locate the
  /// `<accessor>_desc` companion peer by name pattern.
  func forEachSymbol(_ body: (_ name: String, _ vm: UInt64) -> Void)
}

// ==== ---------------------------------------------------------------------
// MARK: Walker

extension AuditImageReader {
  /// Walk the audit records and return one entry per accessible-function
  /// record, in the order the compiler emitted them.
  public func auditDistributedValidation() throws -> [DistributedAuditEntry] {
    guard let acfuncs = accessibleFunctionsSection() else { return [] }
    let daval = davalSection()

    // All relative pointers we resolve are self-relative:
    // `targetFileOffset = fieldFileOffset + i32Delta`. That's correct only
    // when field and target share the same VM/file skew.
    if let d = daval {
      let skewAcfuncs = Int64(acfuncs.vmAddress) - Int64(acfuncs.fileOffset)
      let skewDaval = Int64(d.vmAddress) - Int64(d.fileOffset)
      if skewAcfuncs != skewDaval {
        throw DistributedAuditError.skewMismatch(a: acfuncs.label,
                                                 b: d.label)
      }
    }

    let recordSize = DistributedAuditABI.accessibleFunctionRecordSize
    guard acfuncs.size % recordSize == 0 else {
      throw DistributedAuditError.acfuncsSizeNotMultiple(
        size: acfuncs.size, recordSize: recordSize)
    }
    let count = acfuncs.size / recordSize

    var out: [DistributedAuditEntry] = []
    out.reserveCapacity(count)

    for i in 0..<count {
      let recordOff = acfuncs.fileOffset + i * recordSize
      out.append(try decodeAcfuncRecord(index: i, recordOff: recordOff,
                                        daval: daval))
    }
    return out
  }

  private func decodeAcfuncRecord(index i: Int, recordOff: Int,
                                  daval: AuditSection?)
      throws -> DistributedAuditEntry {
    guard let nameDelta = readInt32(atFileOffset: recordOff) else {
      throw DistributedAuditError.truncatedRecord(index: i, field: "Name")
    }
    guard nameDelta != 0 else {
      throw DistributedAuditError.nullNamePointer(index: i)
    }
    let nameOff = recordOff + Int(nameDelta)
    guard let mangled = readCString(atFileOffset: nameOff) else {
      throw DistributedAuditError.unreadableName(index: i, offset: nameOff)
    }

    let flagsOff = recordOff + DistributedAuditABI.flagsFieldOffset
    guard let flags = readUInt32(atFileOffset: flagsOff) else {
      throw DistributedAuditError.truncatedRecord(index: i, field: "Flags")
    }
    let isDistributed = (flags & DistributedAuditABI.flagIsDistributed) != 0
    let hasValidation = (flags & DistributedAuditABI.flagHasValidation) != 0

    var validators: [DistributedValidator] = []
    if hasValidation {
      guard let d = daval else {
        throw DistributedAuditError.hasValidationWithoutDavalSection(
          record: mangled)
      }
      validators = try walkDavalList(headFlagsOff: flagsOff, flags: flags,
                                     record: mangled, daval: d)
    }

    return DistributedAuditEntry(
      mangledName: mangled,
      isDistributed: isDistributed,
      hasValidation: hasValidation,
      validators: validators)
  }

  private func walkDavalList(headFlagsOff: Int, flags: UInt32,
                             record: String,
                             daval: AuditSection)
      throws -> [DistributedValidator] {
    // Flags word is a tagged relative pointer: bits 2..31 form a signed
    // self-relative offset to the head daval record. Clear the tag bits
    // before sign-extending.
    let masked = flags & ~DistributedAuditABI.flagTagMask
    let signedDelta = Int32(bitPattern: masked)
    var recOff = headFlagsOff + Int(signedDelta)

    var out: [DistributedValidator] = []
    var walked = 0
    while true {
      if walked >= DistributedAuditABI.davalListMaxLength {
        throw DistributedAuditError.runawayDavalList(record: record,
                                                     walked: walked)
      }
      walked += 1

      guard let kind = readUInt32(atFileOffset: recOff) else {
        throw DistributedAuditError.truncatedDaval(record: record,
                                                    field: "kind")
      }
      guard kind == DistributedAuditABI.davalKindValidation else {
        throw DistributedAuditError.unknownDavalKind(record: record,
                                                     kind: kind)
      }
      guard let accDelta = readInt32(
              atFileOffset: recOff + DistributedAuditABI.davalAccessorFieldOffset) else {
        throw DistributedAuditError.truncatedDaval(record: record,
                                                    field: "relAccessor")
      }
      guard accDelta != 0 else {
        throw DistributedAuditError.nullAccessorPointer(record: record)
      }
      let accessorVMAddr = resolveVMAddress(
          fieldFileOffset: recOff + DistributedAuditABI.davalAccessorFieldOffset,
          delta: Int(accDelta),
          section: daval)
      let accessorSymbol = symbolName(atVMAddress: accessorVMAddr)
      let policyText = policyTextForAccessor(accessorSymbol)
      out.append(DistributedValidator(accessorSymbol: accessorSymbol,
                                      policyText: policyText))

      guard let nextDelta = readInt32(
              atFileOffset: recOff + DistributedAuditABI.davalNextFieldOffset) else {
        throw DistributedAuditError.truncatedDaval(record: record,
                                                    field: "relNext")
      }
      if nextDelta == 0 { break }
      recOff = (recOff + DistributedAuditABI.davalNextFieldOffset) + Int(nextDelta)
    }
    return out
  }

  private func policyTextForAccessor(_ accessorSymbol: String?) -> String? {
    guard let sym = accessorSymbol else { return nil }
    guard let attrTag = auditAttributeTag(inMangledSymbol: sym) else {
      return nil
    }
    guard let descSection = descriptionSection() else { return nil }

    var result: String? = nil
    forEachSymbol { name, vm in
      guard result == nil else { return }
      guard name.contains(attrTag), name.contains("_desc") else { return }
      guard vm >= descSection.vmAddress,
            vm < descSection.vmAddress + UInt64(descSection.size) else {
        return
      }
      let skew = Int64(descSection.vmAddress) - Int64(descSection.fileOffset)
      let off = Int(Int64(vm) - skew)
      result = readCString(atFileOffset: off)
    }
    return result
  }

  /// Extracts the per-attribute portion of the mangled name, ending at the
  /// peer-macro marker `fMp_`. Present in both the accessor and its `_desc`
  /// sibling, unique across stacked attributes.
  private func auditAttributeTag(inMangledSymbol s: String) -> String? {
    guard let mp = s.range(of: "fMp") else { return nil }
    let afterMp = mp.upperBound
    let end: String.Index
    if afterMp < s.endIndex && s[afterMp] == "_" {
      end = s.index(after: afterMp)
    } else {
      end = afterMp
    }
    return String(s[..<end])
  }

  private func resolveVMAddress(fieldFileOffset: Int, delta: Int,
                                section: AuditSection) -> UInt64 {
    let skew = Int64(section.vmAddress) - Int64(section.fileOffset)
    let fieldVM = Int64(fieldFileOffset) + skew
    return UInt64(fieldVM + Int64(delta))
  }
}
