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

// Byte-level Mach-O fixture used by `DistributedValidationAuditTests`.
//
// The distributed-audit walker parses a real Mach-O image: section headers,
// symbol table, relative pointers with VM/file skew. To exercise it faithfully
// without shelling out to the compiler, we assemble a minimal valid
// `MH_MAGIC_64` file on disk with just the sections the walker touches:
//
//   __TEXT,__swift5_acfuncs   accessible-function records (20 bytes each)
//   __TEXT,__cstring          mangled thunk names + policy `_desc` strings
//   __DATA_CONST,__swift5_daval    validator linked-list records (16 bytes)
//   __DATA_CONST,__swift5_davala   accessor VM slots (8 bytes each)
//
// VM addresses are laid out so every section shares the same VM/file skew
// (walker requires this; a dedicated test corrupts one to exercise the
// `skewMismatch` branch).
//
// Symbol table (LC_SYMTAB) carries one nlist_64 entry per accessor VM slot,
// with the mangled accessor name plus, optionally, its `<accessor>_desc`
// companion whose VM value points into __cstring.

#if canImport(MachO)

import Foundation
import MachO
import SwiftInspectAudit
@testable import SwiftInspectMachO

// ==== ---------------------------------------------------------------------
// MARK: Public types

/// Description of one accessible-function record the fixture should emit.
struct AcfuncsRecord {
  var mangledName: String
  var isDistributed: Bool
  var hasValidation: Bool
  /// Indices into `SyntheticMachO.accessors`; the linked list is emitted in
  /// this order. Empty when `hasValidation == false`.
  var validatorAccessorIndices: [Int]
}

/// Description of one validator accessor the fixture should emit.
///
/// Each accessor occupies an 8-byte slot in `__DATA_CONST,__swift5_davala`,
/// gets an nlist_64 symbol at that VM address with `mangledName`, and can
/// optionally have a companion `<accessor>_desc` symbol pointing into
/// `__TEXT,__cstring` at `policyText`.
///
/// The `mangledName` uses the compiler's `fMp_` peer-macro marker so the
/// walker's `auditAttributeTag` can extract the per-attribute portion; the
/// `_desc` peer symbol reuses the tag with `_desc` appended.
struct AccessorSpec {
  /// Full mangled accessor symbol name. Must contain `fMp` so the walker's
  /// tag extractor produces a non-nil attribute tag.
  var mangledName: String
  /// Policy source text emitted alongside as a `_desc` cstring, or `nil`
  /// to omit the description peer.
  var policyText: String?
}

/// Builder for a synthetic Mach-O binary shaped like what the compiler emits
/// for distributed audit consumption. Populate the fields, call `write()` to
/// serialize to a temp file, and `open()` to hand it to a fresh `MachOFile`.
struct SyntheticMachO {
  /// Accessible-function records emitted, in section order.
  var acfuncsRecords: [AcfuncsRecord] = [
    AcfuncsRecord(mangledName: "$s6bank/transferF",
                  isDistributed: true, hasValidation: true,
                  validatorAccessorIndices: [0])
  ]

  /// Accessors placed in `__swift5_davala` and emitted as symbols. Default
  /// gives tests three distinct validators to reach for. Names deliberately
  /// omit the `fMp` peer-macro marker so `auditAttributeTag` returns nil for
  /// them and no policy-text lookup fires -- tests that exercise policy text
  /// override this array with `fMp_`-bearing names.
  var accessors: [AccessorSpec] = [
    .init(mangledName: "_daval_transfer_accessor_0", policyText: nil),
    .init(mangledName: "_daval_transfer_accessor_1", policyText: nil),
    .init(mangledName: "_daval_transfer_accessor_2", policyText: nil),
  ]

  /// If true, no accessor symbols are placed in LC_SYMTAB (fixture still
  /// has VM slots, just no name binding). Simulates a `strip`ped binary.
  var stripAccessorSymbols: Bool = false

  /// Number of accessor VM slots in `__swift5_davala`. Kept as its own
  /// field so a test can request extra slots beyond the accessor count.
  var accessorVMSlots: Int { accessors.count }

  /// Symbol table shape the fixture will emit. Populated post-write() so
  /// tests can round-trip against `MachOFile.symbolsByVMAddress`.
  private(set) var accessorSymbolsByVM: [UInt64: String] = [:]

  /// The generated file path, valid after `write()` returns.
  private(set) var path: String = ""

  // ==== -------------------------------------------------------------------
  // MARK: Serialize + open

  /// Serialize the fixture to a temp file. Returns `self` so tests can chain
  /// `fixture.write().open()`.
  @discardableResult
  mutating func write() throws -> Self {
    let bytes = try encode()
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("swift-inspect-synthetic-\(UUID().uuidString).macho")
    try bytes.write(to: url)
    path = url.path
    return self
  }

  /// Open the written fixture as a real `MachOFile`.
  func open() throws -> MachOFile {
    try MachOFile(path: path)
  }

  /// Rewrite the size field of the `__swift5_acfuncs` section header of an
  /// existing file, adding `delta` bytes to it. Used to exercise the walker's
  /// "size not a multiple of record size" error path.
  static func corruptAcfuncsSize(from path: String, by delta: Int) -> String {
    let src = try! Data(contentsOf: URL(fileURLWithPath: path))
    var copy = src

    // Walk load commands to find __swift5_acfuncs and mutate its size in-place.
    // The header layout is documented in `parseLoadCommands`; we duplicate
    // just the tiny subset needed here.
    let headerSize = MemoryLayout<mach_header_64>.size
    let ncmds = copy.load(UInt32.self, at: 16)  // mach_header_64.ncmds
    var cursor = headerSize
    for _ in 0..<ncmds {
      let cmd = copy.load(UInt32.self, at: cursor)
      let cmdSize = Int(copy.load(UInt32.self, at: cursor + 4))
      if cmd == UInt32(LC_SEGMENT_64) {
        let nsects = copy.load(UInt32.self, at: cursor + 64)  // segment_command_64.nsects
        let segStart = cursor + MemoryLayout<segment_command_64>.size
        for i in 0..<Int(nsects) {
          let so = segStart + i * MemoryLayout<section_64>.size
          let name = copy.withUnsafeBytes { raw -> String in
            let base = raw.baseAddress!.advanced(by: so).assumingMemoryBound(to: UInt8.self)
            return String(decoding: UnsafeBufferPointer(start: base, count: 16)
                            .prefix(while: { $0 != 0 }),
                          as: UTF8.self)
          }
          if name == "__swift5_acfuncs" {
            // section_64.size is at offset 40 within section_64
            let sizeOff = so + 40
            let cur = copy.load(UInt64.self, at: sizeOff)
            let mutated = UInt64(Int(cur) + delta)
            copy.store(mutated, at: sizeOff)
            break
          }
        }
      }
      cursor += cmdSize
    }

    let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("swift-inspect-synthetic-corrupt-\(UUID().uuidString).macho")
    try! copy.write(to: outURL)
    return outURL.path
  }

  // ==== -------------------------------------------------------------------
  // MARK: Encoder
  //
  // Layout (all offsets/VM at 16-byte alignment, single __TEXT and single
  // __DATA_CONST segment; VM address == file offset so skew is zero):
  //
  //   [0]                           mach_header_64
  //   [headerEnd]                   LC_SEGMENT_64 __TEXT     (3 sections)
  //   [.]                           LC_SEGMENT_64 __DATA_CONST (2 sections)
  //   [.]                           LC_SYMTAB
  //   [textFileOff]                 __TEXT,__swift5_acfuncs
  //   [.]                           __TEXT,__cstring
  //   [.]                           __TEXT,__davala_stub  (never used;
  //                                    kept so __TEXT has a stable size)
  //   [dataFileOff]                 __DATA_CONST,__swift5_daval
  //   [.]                           __DATA_CONST,__swift5_davala
  //   [symtabOff]                   nlist_64 array
  //   [strtabOff]                   string table
  //
  // Every payload address is picked so `vmAddress == fileOffset`; the
  // walker computes `skew = vmAddress - fileOffset` per section and
  // requires all skews equal, so uniform zero satisfies it trivially.

  private mutating func encode() throws -> Data {
    // ---- Section payload construction ----
    let acfuncsRecordSize = DistributedAuditABI.accessibleFunctionRecordSize
    let acfuncsSize = acfuncsRecords.count * acfuncsRecordSize

    // Build the cstring section: each acfuncs record's Name field points
    // at a nul-terminated mangled function name; each accessor with a
    // policy text points at a nul-terminated policy string here too.
    var cstringBytes = Data()
    var nameOffsetInCstring: [Int: Int] = [:]  // acfuncs record idx -> offset
    for (i, rec) in acfuncsRecords.enumerated() {
      nameOffsetInCstring[i] = cstringBytes.count
      cstringBytes.append(Data(rec.mangledName.utf8))
      cstringBytes.append(0)
    }
    var descOffsetInCstring: [Int: Int] = [:]  // accessor idx -> offset
    for (i, a) in accessors.enumerated() {
      guard let policy = a.policyText else { continue }
      descOffsetInCstring[i] = cstringBytes.count
      cstringBytes.append(Data(policy.utf8))
      cstringBytes.append(0)
    }
    // Pad cstring to multiple of 16 so subsequent sections align nicely.
    while cstringBytes.count % 16 != 0 { cstringBytes.append(0) }
    let cstringSize = cstringBytes.count

    // Stub section that soaks up the space between __cstring and __DATA_CONST
    // if any padding is desired. Kept size 0 by default.
    let stubSize = 0

    // daval records: 4 x i32 each.
    // Field layout (matches DistributedAuditABI):
    //   [0] kind  (i32) = 'dval' little-endian
    //   [4] reserved (i32) = 0
    //   [8] relAccessor (i32) = self-relative offset from THIS field to
    //       the accessor VM slot in __swift5_davala
    //   [12] relNext (i32) = self-relative offset from THIS field to the
    //       next daval record, or 0 for the tail

    // Layout math: we emit one daval record per validator per acfuncs entry.
    // Records are contiguous in section order matching validation walk order.
    struct DavalRecordPlan {
      var acfuncsIdx: Int
      var indexInList: Int   // 0-based position in this acfuncs record's chain
      var accessorIdx: Int
      var isTail: Bool
    }
    var davalPlan: [DavalRecordPlan] = []
    for (i, rec) in acfuncsRecords.enumerated() where rec.hasValidation {
      let indices = rec.validatorAccessorIndices
      for (n, aidx) in indices.enumerated() {
        davalPlan.append(.init(acfuncsIdx: i, indexInList: n,
                               accessorIdx: aidx,
                               isTail: n == indices.count - 1))
      }
    }
    let davalRecordSize = DistributedAuditABI.davalRecordSize
    let davalSize = davalPlan.count * davalRecordSize

    // Accessor VM slots: 8 bytes each. Content is arbitrary; the walker only
    // resolves the VM address, not the content.
    let davalaSize = accessorVMSlots * 8

    // ---- Compute file/VM addresses ----
    // Header + 3 load commands (TEXT segment with 3 sections, DATA_CONST
    // segment with 2 sections, SYMTAB).
    let mh64Size = MemoryLayout<mach_header_64>.size
    let seg64HdrSize = MemoryLayout<segment_command_64>.size
    let sect64Size = MemoryLayout<section_64>.size
    let symtabCmdSize = MemoryLayout<symtab_command>.size
    let textSegSize = seg64HdrSize + 3 * sect64Size
    let dataSegSize = seg64HdrSize + 2 * sect64Size
    let loadCmdsSize = textSegSize + dataSegSize + symtabCmdSize

    // Round the start of payload data up to 16-byte alignment so section
    // VM addresses stay tidy.
    func align16(_ x: Int) -> Int { (x + 15) & ~15 }

    let textFileOff = align16(mh64Size + loadCmdsSize)
    let acfuncsOff  = textFileOff
    let cstringOff  = acfuncsOff + acfuncsSize
    let stubOff     = cstringOff + cstringSize
    let textEndOff  = stubOff + stubSize
    let dataFileOff = align16(textEndOff)
    let davalOff    = dataFileOff
    let davalaOff   = davalOff + davalSize
    let dataEndOff  = davalaOff + davalaSize

    // Symbol table: one nlist_64 per accessor (unless stripped), plus one
    // per policy-text-bearing accessor for the `_desc` companion. Names go
    // in the string table.
    struct SymPlan {
      var name: String
      var vmAddress: UInt64
    }
    var symPlan: [SymPlan] = []
    var accessorVM: [Int: UInt64] = [:]
    for i in 0..<accessorVMSlots {
      accessorVM[i] = UInt64(davalaOff + i * 8)
    }
    if !stripAccessorSymbols {
      for (i, a) in accessors.enumerated() {
        symPlan.append(.init(name: a.mangledName,
                             vmAddress: accessorVM[i]!))
      }
    }
    // `_desc` peer: an nlist symbol pointing at the cstring VM address of
    // the policy text. Its NAME is what the walker matches on
    // (`attrTag + "_desc"`), so it always shows up regardless of the strip
    // flag on the accessor. The walker's tag extractor stops at `fMp_`, so
    // reusing the accessor's mangled prefix and appending `_desc` works.
    for (i, a) in accessors.enumerated() {
      guard let _ = a.policyText, let off = descOffsetInCstring[i] else { continue }
      symPlan.append(.init(name: "\(a.mangledName)_desc",
                           vmAddress: UInt64(cstringOff + off)))
    }

    // String table: nlist_64.n_strx == 0 means "no name", so the table
    // starts with a single NUL byte for the null-name slot.
    var strtabBytes = Data([0])
    var symNameOffsets: [Int] = []
    for s in symPlan {
      symNameOffsets.append(strtabBytes.count)
      strtabBytes.append(Data(s.name.utf8))
      strtabBytes.append(0)
    }
    let symtabOff = align16(dataEndOff)
    let nlistSize = MemoryLayout<nlist_64>.size
    let strtabOff = symtabOff + symPlan.count * nlistSize
    let strtabSize = strtabBytes.count
    let fileEnd = strtabOff + strtabSize

    // Record symbol table for tests to compare against.
    accessorSymbolsByVM = [:]
    for s in symPlan {
      accessorSymbolsByVM[s.vmAddress] = s.name
    }

    // ---- Emit bytes ----
    var out = Data(count: fileEnd)

    // mach_header_64
    var header = mach_header_64(
      magic: MH_MAGIC_64,
      cputype: CPU_TYPE_ARM64,
      cpusubtype: CPU_SUBTYPE_ARM64_ALL,
      filetype: UInt32(MH_DYLIB),
      ncmds: 3,
      sizeofcmds: UInt32(loadCmdsSize),
      flags: 0,
      reserved: 0)
    out.store(&header, at: 0, size: mh64Size)

    // LC_SEGMENT_64 __TEXT
    var textSeg = segment_command_64(
      cmd: UInt32(LC_SEGMENT_64),
      cmdsize: UInt32(textSegSize),
      segname: fixedCharTuple16("__TEXT"),
      vmaddr: UInt64(textFileOff),
      vmsize: UInt64(textEndOff - textFileOff),
      fileoff: UInt64(textFileOff),
      filesize: UInt64(textEndOff - textFileOff),
      maxprot: 5, initprot: 5,
      nsects: 3, flags: 0)
    var cursor = mh64Size
    out.store(&textSeg, at: cursor, size: seg64HdrSize)
    cursor += seg64HdrSize
    out.storeSection64(at: cursor, name: "__swift5_acfuncs", seg: "__TEXT",
                       addr: UInt64(acfuncsOff), size: UInt64(acfuncsSize),
                       offset: UInt32(acfuncsOff))
    cursor += sect64Size
    out.storeSection64(at: cursor, name: "__cstring", seg: "__TEXT",
                       addr: UInt64(cstringOff), size: UInt64(cstringSize),
                       offset: UInt32(cstringOff))
    cursor += sect64Size
    out.storeSection64(at: cursor, name: "__davala_stub", seg: "__TEXT",
                       addr: UInt64(stubOff), size: UInt64(stubSize),
                       offset: UInt32(stubOff))
    cursor += sect64Size

    // LC_SEGMENT_64 __DATA_CONST
    var dataSeg = segment_command_64(
      cmd: UInt32(LC_SEGMENT_64),
      cmdsize: UInt32(dataSegSize),
      segname: fixedCharTuple16("__DATA_CONST"),
      vmaddr: UInt64(dataFileOff),
      vmsize: UInt64(dataEndOff - dataFileOff),
      fileoff: UInt64(dataFileOff),
      filesize: UInt64(dataEndOff - dataFileOff),
      maxprot: 3, initprot: 3,
      nsects: 2, flags: 0)
    out.store(&dataSeg, at: cursor, size: seg64HdrSize)
    cursor += seg64HdrSize
    out.storeSection64(at: cursor, name: "__swift5_daval", seg: "__DATA_CONST",
                       addr: UInt64(davalOff), size: UInt64(davalSize),
                       offset: UInt32(davalOff))
    cursor += sect64Size
    out.storeSection64(at: cursor, name: "__swift5_davala", seg: "__DATA_CONST",
                       addr: UInt64(davalaOff), size: UInt64(davalaSize),
                       offset: UInt32(davalaOff))
    cursor += sect64Size

    // LC_SYMTAB
    var symtab = symtab_command(
      cmd: UInt32(LC_SYMTAB),
      cmdsize: UInt32(symtabCmdSize),
      symoff: UInt32(symtabOff),
      nsyms: UInt32(symPlan.count),
      stroff: UInt32(strtabOff),
      strsize: UInt32(strtabSize))
    out.store(&symtab, at: cursor, size: symtabCmdSize)

    // Payload: accessible-function records.
    // AccessibleFunctionRecord = 4 x RelativeDirectPointer<...> (i32) + i32 Flags.
    // Only Name (offset 0) and Flags (offset 16) are meaningful here; the other
    // pointers are left as 0.
    for (i, rec) in acfuncsRecords.enumerated() {
      let recOff = acfuncsOff + i * acfuncsRecordSize
      let nameTargetOff = cstringOff + (nameOffsetInCstring[i] ?? 0)
      let nameDelta = Int32(nameTargetOff - recOff)
      out.store(UInt32(bitPattern: nameDelta), at: recOff)
      // GenericEnv, FunctionType, Function -- leave zeroed.
      out.store(UInt32(0), at: recOff + 4)
      out.store(UInt32(0), at: recOff + 8)
      out.store(UInt32(0), at: recOff + 12)

      var flags: UInt32 = 0
      if rec.isDistributed { flags |= DistributedAuditABI.flagIsDistributed }
      if rec.hasValidation {
        flags |= DistributedAuditABI.flagHasValidation
        // The head daval record for this acfuncs entry is the first daval
        // whose plan.acfuncsIdx == i (they're emitted contiguously in that
        // order above, so we can look it up by predicate).
        if let firstDavalIdx = davalPlan.firstIndex(where: { $0.acfuncsIdx == i }) {
          let headOff = davalOff + firstDavalIdx * davalRecordSize
          let flagsFieldOff = recOff + DistributedAuditABI.flagsFieldOffset
          let signedDelta = Int32(headOff - flagsFieldOff)
          // Flags is a tagged relative pointer: the low 2 bits carry the
          // isDistributed/hasValidation flags, the upper bits are the signed
          // delta. Reconstruct with the flags OR'd in.
          let asBits = UInt32(bitPattern: signedDelta) & ~DistributedAuditABI.flagTagMask
          flags = asBits | flags
        }
      }
      out.store(flags, at: recOff + DistributedAuditABI.flagsFieldOffset)
    }

    // Payload: cstring section.
    out.replaceSubrange(cstringOff..<(cstringOff + cstringSize), with: cstringBytes)

    // Payload: daval records.
    for (i, plan) in davalPlan.enumerated() {
      let recOff = davalOff + i * davalRecordSize
      // kind
      out.store(DistributedAuditABI.davalKindValidation, at: recOff)
      // reserved
      out.store(UInt32(0), at: recOff + 4)
      // relAccessor -- self-relative from recOff+8 to accessor VM slot
      let accField = recOff + DistributedAuditABI.davalAccessorFieldOffset
      let accessorTargetOff = davalaOff + plan.accessorIdx * 8
      let accDelta = Int32(accessorTargetOff - accField)
      out.store(UInt32(bitPattern: accDelta), at: accField)
      // relNext
      let nextField = recOff + DistributedAuditABI.davalNextFieldOffset
      if plan.isTail {
        out.store(UInt32(0), at: nextField)
      } else {
        let nextRecOff = recOff + davalRecordSize
        let nextDelta = Int32(nextRecOff - nextField)
        out.store(UInt32(bitPattern: nextDelta), at: nextField)
      }
    }

    // Payload: davala slots. Filled with a marker byte pattern so any bug
    // that reads them as bytes has a chance of surfacing.
    for i in 0..<accessorVMSlots {
      let slotOff = davalaOff + i * 8
      // 0xDEAD..., different per slot so a mistaken read is easier to spot.
      let marker: UInt64 = 0xDEADBEEF_00000000 | UInt64(i)
      out.store(marker, at: slotOff)
    }

    // Payload: nlist_64 array.
    for (i, s) in symPlan.enumerated() {
      var nlist = nlist_64(
        n_un: .init(n_strx: UInt32(symNameOffsets[i])),
        n_type: UInt8(N_SECT | N_EXT),
        n_sect: 1,   // arbitrary; the walker only uses n_value + n_strx.
        n_desc: 0,
        n_value: s.vmAddress)
      let dst = symtabOff + i * nlistSize
      out.store(&nlist, at: dst, size: nlistSize)
    }

    // Payload: string table.
    out.replaceSubrange(strtabOff..<(strtabOff + strtabSize), with: strtabBytes)

    return out
  }
}

// ==== ---------------------------------------------------------------------
// MARK: Data primitives
//
// The Mach-O structs are C tuples of fixed-width scalars, so we can just
// blit them into the mutable buffer. All values are little-endian on the
// Darwin platforms swift-inspect ships on.

private extension Data {
  mutating func store<T>(_ value: T, at offset: Int) where T: FixedWidthInteger {
    var v = value
    Swift.withUnsafeBytes(of: &v) { src in
      self.replaceSubrange(offset..<(offset + MemoryLayout<T>.size),
                           with: src)
    }
  }

  mutating func store<T>(_ value: inout T, at offset: Int, size: Int) {
    Swift.withUnsafeBytes(of: &value) { src in
      self.replaceSubrange(offset..<(offset + size),
                           with: UnsafeBufferPointer(
                             start: src.baseAddress!.assumingMemoryBound(to: UInt8.self),
                             count: size))
    }
  }

  func load<T>(_: T.Type, at offset: Int) -> T {
    withUnsafeBytes { $0.load(fromByteOffset: offset, as: T.self) }
  }

  mutating func storeSection64(at offset: Int, name: String, seg: String,
                               addr: UInt64, size: UInt64, offset off: UInt32) {
    var sect = section_64(
      sectname: fixedCharTuple16(name),
      segname: fixedCharTuple16(seg),
      addr: addr,
      size: size,
      offset: off,
      align: 4,
      reloff: 0,
      nreloc: 0,
      flags: 0,
      reserved1: 0,
      reserved2: 0,
      reserved3: 0)
    Swift.withUnsafeBytes(of: &sect) { src in
      self.replaceSubrange(offset..<(offset + MemoryLayout<section_64>.size),
                           with: src)
    }
  }
}

/// Pack a Swift `String` into the 16-byte fixed C char tuple Mach-O uses for
/// segment/section names. Names >= 16 bytes are truncated (Mach-O convention:
/// no NUL terminator required when the name fills the whole field).
private func fixedCharTuple16(_ s: String) -> (CChar, CChar, CChar, CChar,
                                                CChar, CChar, CChar, CChar,
                                                CChar, CChar, CChar, CChar,
                                                CChar, CChar, CChar, CChar) {
  var buf = [CChar](repeating: 0, count: 16)
  for (i, b) in s.utf8.prefix(16).enumerated() {
    buf[i] = CChar(bitPattern: b)
  }
  return (buf[0], buf[1], buf[2], buf[3],
          buf[4], buf[5], buf[6], buf[7],
          buf[8], buf[9], buf[10], buf[11],
          buf[12], buf[13], buf[14], buf[15])
}

#endif  // canImport(MachO)
