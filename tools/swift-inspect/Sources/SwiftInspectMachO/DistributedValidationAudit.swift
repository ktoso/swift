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

// Offline decoder for the distributed remote-call validation ABI emitted
// by the compiler. Reads:
//
//   __TEXT,__swift5_acfuncs  -> TargetAccessibleFunctionRecord array
//   __DATA_CONST,__swift5_daval -> validation record linked list
//        { i32 kind='dval', i32 reserved, i32 relAccessor, i32 relNext }
//   __DATA_CONST,__swift5_davala -> validation accessor closures
//
// The accessible-function record's Flags field is a tagged relative pointer
// to the head of the daval linked list when bit 1 (HasValidation) is set.
// See lib/IRGen/GenDecl.cpp:emitAccessibleFunction and
// stdlib/public/Distributed/DistributedValidation.swift for the emit and
// receive sides.

#if canImport(MachO)

import Foundation

/// A single row of audit output: one accessible-function record and any
/// validators attached to it.
public struct DistributedAuditEntry: Equatable {
  public var mangledName: String
  public var isDistributed: Bool
  public var hasValidation: Bool
  /// Symbol names of the validation accessors linked from this entry, in
  /// list order. `nil` means the symbol was stripped from the binary.
  public var validatorSymbols: [String?]

  public init(mangledName: String, isDistributed: Bool,
              hasValidation: Bool, validatorSymbols: [String?]) {
    self.mangledName = mangledName
    self.isDistributed = isDistributed
    self.hasValidation = hasValidation
    self.validatorSymbols = validatorSymbols
  }
}

public enum DistributedAuditError: Error, CustomStringConvertible {
  case skewMismatch(a: MachOSection, b: MachOSection)
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
      return "sections have inconsistent VM/file skew: " +
             "\(a.segment),\(a.section) vs \(b.segment),\(b.section); " +
             "offline audit cannot resolve relative pointers safely."
    case .acfuncsSizeNotMultiple(let size, let recordSize):
      return "__swift5_acfuncs size (\(size)) is not a multiple of \(recordSize)"
    case .truncatedRecord(let i, let f):
      return "record #\(i): truncated \(f)"
    case .nullNamePointer(let i):
      return "record #\(i): null Name relative pointer"
    case .unreadableName(let i, let off):
      return "record #\(i): could not read Name string at file offset \(off)"
    case .hasValidationWithoutDavalSection(let r):
      return "record for \(r) has HasValidation set but " +
             "__DATA_CONST,__swift5_daval is absent"
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

/// Sizes/masks that make up the on-disk ABI of the audit records. Kept
/// here so tests can reference them by name instead of magic numbers.
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

extension MachOFile {
  /// Walk the audit records and return one entry per accessible-function
  /// record. The order is the same order the compiler emitted the records
  /// (i.e. same order as `otool -s __TEXT __swift5_acfuncs` would report).
  public func auditDistributedValidation() throws -> [DistributedAuditEntry] {
    guard let acfuncs = findSection(segment: "__TEXT", section: "__swift5_acfuncs") else {
      return []
    }
    let daval = findSection(segment: "__DATA_CONST", section: "__swift5_daval")

    // All relative pointers we resolve are self-relative:
    // `targetFileOffset = fieldFileOffset + i32Delta`. That is correct
    // only when field and target share the same VM/file skew. Assert.
    if let d = daval {
      let skewAcfuncs = Int64(acfuncs.vmAddress) - Int64(acfuncs.fileOffset)
      let skewDaval = Int64(d.vmAddress) - Int64(d.fileOffset)
      if skewAcfuncs != skewDaval {
        throw DistributedAuditError.skewMismatch(a: acfuncs, b: d)
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
                                  daval: MachOSection?)
      throws -> DistributedAuditEntry {
    // Name: non-null relative pointer to a C string.
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

    // Flags at offset 16.
    let flagsOff = recordOff + DistributedAuditABI.flagsFieldOffset
    guard let flags = readUInt32(atFileOffset: flagsOff) else {
      throw DistributedAuditError.truncatedRecord(index: i, field: "Flags")
    }
    let isDistributed = (flags & DistributedAuditABI.flagIsDistributed) != 0
    let hasValidation = (flags & DistributedAuditABI.flagHasValidation) != 0

    var validators: [String?] = []
    if hasValidation {
      guard daval != nil else {
        throw DistributedAuditError.hasValidationWithoutDavalSection(
          record: mangled)
      }
      validators = try walkDavalList(headFlagsOff: flagsOff, flags: flags,
                                     record: mangled, daval: daval!)
    }

    return DistributedAuditEntry(
      mangledName: mangled,
      isDistributed: isDistributed,
      hasValidation: hasValidation,
      validatorSymbols: validators)
  }

  private func walkDavalList(headFlagsOff: Int, flags: UInt32,
                             record: String,
                             daval: MachOSection)
      throws -> [String?] {
    // The Flags word is a tagged relative pointer: bits 2..31 form a
    // signed self-relative offset to the head daval record. Clear the
    // low 2 tag bits before sign-extending.
    let masked = flags & ~DistributedAuditABI.flagTagMask
    let signedDelta = Int32(bitPattern: masked)
    var recOff = headFlagsOff + Int(signedDelta)

    var out: [String?] = []
    var walked = 0
    while true {
      if walked >= DistributedAuditABI.davalListMaxLength {
        throw DistributedAuditError.runawayDavalList(
          record: record, walked: walked)
      }
      walked += 1

      guard let kind = readUInt32(atFileOffset: recOff) else {
        throw DistributedAuditError.truncatedDaval(record: record, field: "kind")
      }
      guard kind == DistributedAuditABI.davalKindValidation else {
        throw DistributedAuditError.unknownDavalKind(record: record, kind: kind)
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
      out.append(symbolsByVMAddress[accessorVMAddr])

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

  /// Turn a field-file-offset + self-relative delta into a VM address so we
  /// can look up the target symbol in the nlist table (which is keyed by
  /// VM address, not file offset).
  public func resolveVMAddress(fieldFileOffset: Int, delta: Int,
                               section: MachOSection) -> UInt64 {
    let skew = Int64(section.vmAddress) - Int64(section.fileOffset)
    let fieldVM = Int64(fieldFileOffset) + skew
    return UInt64(fieldVM + Int64(delta))
  }
}

#endif  // canImport(MachO)
