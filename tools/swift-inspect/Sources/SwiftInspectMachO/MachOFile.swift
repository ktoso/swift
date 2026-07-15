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

// Minimal Mach-O reader used by the offline `distributed audit` subcommand.
// This is intentionally narrow: it opens a mapped file, walks the load
// commands to enumerate segments/sections and the symbol table, and hands
// out slices/offsets. It does not attempt to be a general-purpose parser.
// If we ever need more coverage we should reach for MachOKit instead.

#if canImport(MachO)

import Foundation
import MachO

public enum MachOAuditError: Error, CustomStringConvertible {
  case fileTooSmall(_ path: String)
  case notMachO(_ path: String, magic: UInt32)
  case unsupportedFatMachO(_ path: String)
  case archNotFound(_ path: String, requested: String, available: [String])
  case malformed(_ path: String, _ detail: String)

  public var description: String {
    switch self {
    case .fileTooSmall(let p):
      return "\(p): file smaller than a Mach-O header"
    case .notMachO(let p, let magic):
      return "\(p): not a Mach-O file (magic=0x\(String(magic, radix: 16)))"
    case .unsupportedFatMachO(let p):
      return "\(p): fat Mach-O; pass --arch to select a slice"
    case .archNotFound(let p, let req, let avail):
      return "\(p): arch '\(req)' not present; available: \(avail.joined(separator: ", "))"
    case .malformed(let p, let d):
      return "\(p): malformed Mach-O (\(d))"
    }
  }
}

/// One Mach-O section, resolved to a slice of the on-disk file.
public struct MachOSection {
  public var segment: String
  public var section: String
  public var fileOffset: Int   // byte offset from start of the mapped file
  public var vmAddress: UInt64
  public var size: Int

  public init(segment: String, section: String, fileOffset: Int,
              vmAddress: UInt64, size: Int) {
    self.segment = segment
    self.section = section
    self.fileOffset = fileOffset
    self.vmAddress = vmAddress
    self.size = size
  }
}

/// One nlist symbol, keyed later by VM address.
public struct MachOSymbol {
  public var name: String
  public var vmAddress: UInt64

  public init(name: String, vmAddress: UInt64) {
    self.name = name
    self.vmAddress = vmAddress
  }
}

public final class MachOFile {
  public let path: String
  public let data: Data
  public let is64: Bool
  /// File offset of the mach_header for this slice. Non-zero only for a
  /// slice inside a fat Mach-O.
  public let sliceOffset: Int
  public let sections: [MachOSection]
  public let symbolsByVMAddress: [UInt64: String]

  public init(path: String, arch: String? = nil) throws {
    self.path = path
    self.data = try Data(contentsOf: URL(fileURLWithPath: path),
                         options: .alwaysMapped)
    guard data.count >= 4 else { throw MachOAuditError.fileTooSmall(path) }

    let magic = data.load(UInt32.self, at: 0)
    switch magic {
    case FAT_MAGIC, FAT_CIGAM, FAT_MAGIC_64, FAT_CIGAM_64:
      let picked = try MachOFile.pickFatSlice(data: data, path: path,
                                              arch: arch, magic: magic)
      self.sliceOffset = picked.offset
    case MH_MAGIC_64, MH_CIGAM_64, MH_MAGIC, MH_CIGAM:
      self.sliceOffset = 0
    default:
      throw MachOAuditError.notMachO(path, magic: magic)
    }

    let sliceMagic = data.load(UInt32.self, at: sliceOffset)
    guard sliceMagic == MH_MAGIC_64 || sliceMagic == MH_CIGAM_64
       || sliceMagic == MH_MAGIC   || sliceMagic == MH_CIGAM else {
      throw MachOAuditError.notMachO(path, magic: sliceMagic)
    }
    // Byte-swapping magics indicate the file was written for the opposite
    // endianness of the current host. We do not support that; all Darwin
    // Mach-O we care about here is little-endian and matches our host.
    guard sliceMagic == MH_MAGIC_64 || sliceMagic == MH_MAGIC else {
      throw MachOAuditError.malformed(path, "byte-swapped Mach-O not supported")
    }
    self.is64 = (sliceMagic == MH_MAGIC_64)

    let (sections, symbols) = try MachOFile.parseLoadCommands(
        data: data, sliceOffset: sliceOffset, is64: self.is64, path: path)
    self.sections = sections

    var byAddr: [UInt64: String] = [:]
    byAddr.reserveCapacity(symbols.count)
    for s in symbols where s.vmAddress != 0 {
      // Prefer the first mapping we see for a given address; multiple
      // aliases at the same address are uncommon in what we scan.
      if byAddr[s.vmAddress] == nil {
        byAddr[s.vmAddress] = s.name
      }
    }
    self.symbolsByVMAddress = byAddr
  }

  public func findSection(segment: String, section: String) -> MachOSection? {
    for s in sections where s.segment == segment && s.section == section {
      return s
    }
    return nil
  }

  /// Read a UTF-8 C string at a file offset, up to a reasonable cap.
  public func readCString(atFileOffset off: Int) -> String? {
    guard off >= 0 && off < data.count else { return nil }
    let end = min(off + 4096, data.count)
    return data.withUnsafeBytes { raw -> String? in
      let base = raw.baseAddress!.advanced(by: off).assumingMemoryBound(to: UInt8.self)
      var len = 0
      while len < end - off && base.advanced(by: len).pointee != 0 { len += 1 }
      return String(decoding: UnsafeBufferPointer(start: base, count: len),
                    as: UTF8.self)
    }
  }

  /// Read an Int32 at a file offset.
  public func readInt32(atFileOffset off: Int) -> Int32? {
    guard off >= 0, off + 4 <= data.count else { return nil }
    return Int32(bitPattern: data.load(UInt32.self, at: off))
  }

  public func readUInt32(atFileOffset off: Int) -> UInt32? {
    guard off >= 0, off + 4 <= data.count else { return nil }
    return data.load(UInt32.self, at: off)
  }

  // ==== -------------------------------------------------------------------
  // MARK: Fat handling

  private static func pickFatSlice(data: Data, path: String,
                                   arch: String?, magic: UInt32)
      throws -> (offset: Int, cputype: cpu_type_t) {
    // fat_header/fat_arch are always big-endian on disk regardless of the
    // slices' endianness -- swap accordingly.
    let is64FatEntry = (magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64)
    let swap = (magic == FAT_CIGAM || magic == FAT_CIGAM_64)
    guard data.count >= MemoryLayout<fat_header>.size else {
      throw MachOAuditError.malformed(path, "truncated fat header")
    }
    let header = data.withUnsafeBytes { $0.load(as: fat_header.self) }
    let nfat = swap ? _OSSwapInt32(header.nfat_arch) : header.nfat_arch

    var entryOffset = MemoryLayout<fat_header>.size
    let entrySize = is64FatEntry
        ? MemoryLayout<fat_arch_64>.size
        : MemoryLayout<fat_arch>.size

    var available: [(name: String, offset: Int, cputype: cpu_type_t)] = []
    for _ in 0..<nfat {
      guard entryOffset + entrySize <= data.count else {
        throw MachOAuditError.malformed(path, "truncated fat entry")
      }
      let cputype: cpu_type_t
      let offset: UInt64
      if is64FatEntry {
        let e = data.withUnsafeBytes {
          $0.load(fromByteOffset: entryOffset, as: fat_arch_64.self)
        }
        cputype = swap ? cpu_type_t(bitPattern: _OSSwapInt32(UInt32(bitPattern: e.cputype))) : e.cputype
        offset = swap ? _OSSwapInt64(e.offset) : e.offset
      } else {
        let e = data.withUnsafeBytes {
          $0.load(fromByteOffset: entryOffset, as: fat_arch.self)
        }
        cputype = swap ? cpu_type_t(bitPattern: _OSSwapInt32(UInt32(bitPattern: e.cputype))) : e.cputype
        offset = UInt64(swap ? _OSSwapInt32(e.offset) : e.offset)
      }
      available.append((name: MachOFile.name(for: cputype),
                        offset: Int(offset), cputype: cputype))
      entryOffset += entrySize
    }

    if let arch = arch {
      if let match = available.first(where: { $0.name == arch }) {
        return (match.offset, match.cputype)
      }
      throw MachOAuditError.archNotFound(path, requested: arch,
                                         available: available.map(\.name))
    }

    // Default: pick the host arch if present, otherwise fail with a hint.
    let host = MachOFile.hostArchName()
    if let match = available.first(where: { $0.name == host }) {
      return (match.offset, match.cputype)
    }
    throw MachOAuditError.unsupportedFatMachO(path)
  }

  private static func name(for cputype: cpu_type_t) -> String {
    // Cover just what we ship on Darwin; anything else falls back to
    // the raw cputype so the caller sees SOMETHING useful.
    switch cputype {
    case CPU_TYPE_ARM64:  return "arm64"
    case CPU_TYPE_X86_64: return "x86_64"
    case CPU_TYPE_ARM:    return "arm"
    case CPU_TYPE_X86:    return "i386"
    default:              return "cputype-\(cputype)"
    }
  }

  private static func hostArchName() -> String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "unknown"
    #endif
  }

  // ==== -------------------------------------------------------------------
  // MARK: Load commands

  private static func parseLoadCommands(data: Data, sliceOffset: Int,
                                        is64: Bool, path: String)
      throws -> (sections: [MachOSection], symbols: [MachOSymbol]) {
    let headerSize = is64
        ? MemoryLayout<mach_header_64>.size
        : MemoryLayout<mach_header>.size
    guard sliceOffset + headerSize <= data.count else {
      throw MachOAuditError.malformed(path, "truncated mach_header")
    }

    let ncmds: UInt32
    if is64 {
      let h = data.withUnsafeBytes {
        $0.load(fromByteOffset: sliceOffset, as: mach_header_64.self)
      }
      ncmds = h.ncmds
    } else {
      let h = data.withUnsafeBytes {
        $0.load(fromByteOffset: sliceOffset, as: mach_header.self)
      }
      ncmds = h.ncmds
    }

    var out: [MachOSection] = []
    var syms: [MachOSymbol] = []
    var cursor = sliceOffset + headerSize

    for _ in 0..<ncmds {
      guard cursor + MemoryLayout<load_command>.size <= data.count else {
        throw MachOAuditError.malformed(path, "truncated load command")
      }
      let cmd = data.withUnsafeBytes {
        $0.load(fromByteOffset: cursor, as: load_command.self)
      }
      let cmdSize = Int(cmd.cmdsize)
      guard cmdSize > 0, cursor + cmdSize <= data.count else {
        throw MachOAuditError.malformed(path, "load command cmdsize out of range")
      }

      switch cmd.cmd {
      case UInt32(LC_SEGMENT_64):
        try parseSegment64(data: data, at: cursor, sliceOffset: sliceOffset,
                           into: &out, path: path)
      case UInt32(LC_SEGMENT):
        try parseSegment32(data: data, at: cursor, sliceOffset: sliceOffset,
                           into: &out, path: path)
      case UInt32(LC_SYMTAB):
        try parseSymtab(data: data, at: cursor, sliceOffset: sliceOffset,
                        is64: is64, into: &syms, path: path)
      default:
        break
      }

      cursor += cmdSize
    }
    return (out, syms)
  }

  private static func parseSegment64(data: Data, at off: Int,
                                     sliceOffset: Int,
                                     into out: inout [MachOSection],
                                     path: String) throws {
    let seg = data.withUnsafeBytes {
      $0.load(fromByteOffset: off, as: segment_command_64.self)
    }
    let segName = withUnsafeBytes(of: seg.segname) { buf -> String in
      String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    var sectOff = off + MemoryLayout<segment_command_64>.size
    for _ in 0..<seg.nsects {
      guard sectOff + MemoryLayout<section_64>.size <= data.count else {
        throw MachOAuditError.malformed(path, "truncated section_64")
      }
      let sect = data.withUnsafeBytes {
        $0.load(fromByteOffset: sectOff, as: section_64.self)
      }
      let sectName = withUnsafeBytes(of: sect.sectname) { buf -> String in
        String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
      }
      out.append(MachOSection(
        segment: segName,
        section: sectName,
        fileOffset: sliceOffset + Int(sect.offset),
        vmAddress: sect.addr,
        size: Int(sect.size)))
      sectOff += MemoryLayout<section_64>.size
    }
  }

  private static func parseSegment32(data: Data, at off: Int,
                                     sliceOffset: Int,
                                     into out: inout [MachOSection],
                                     path: String) throws {
    let seg = data.withUnsafeBytes {
      $0.load(fromByteOffset: off, as: segment_command.self)
    }
    let segName = withUnsafeBytes(of: seg.segname) { buf -> String in
      String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    var sectOff = off + MemoryLayout<segment_command>.size
    for _ in 0..<seg.nsects {
      guard sectOff + MemoryLayout<section>.size <= data.count else {
        throw MachOAuditError.malformed(path, "truncated section")
      }
      let sect = data.withUnsafeBytes {
        $0.load(fromByteOffset: sectOff, as: section.self)
      }
      let sectName = withUnsafeBytes(of: sect.sectname) { buf -> String in
        String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
      }
      out.append(MachOSection(
        segment: segName,
        section: sectName,
        fileOffset: sliceOffset + Int(sect.offset),
        vmAddress: UInt64(sect.addr),
        size: Int(sect.size)))
      sectOff += MemoryLayout<section>.size
    }
  }

  private static func parseSymtab(data: Data, at off: Int, sliceOffset: Int,
                                  is64: Bool,
                                  into out: inout [MachOSymbol],
                                  path: String) throws {
    let cmd = data.withUnsafeBytes {
      $0.load(fromByteOffset: off, as: symtab_command.self)
    }
    let symBase = sliceOffset + Int(cmd.symoff)
    let strBase = sliceOffset + Int(cmd.stroff)
    let strEnd = strBase + Int(cmd.strsize)
    let nsyms = Int(cmd.nsyms)
    guard strEnd <= data.count else {
      throw MachOAuditError.malformed(path, "symtab string table out of range")
    }

    if is64 {
      let stride = MemoryLayout<nlist_64>.size
      guard symBase + stride * nsyms <= data.count else {
        throw MachOAuditError.malformed(path, "symtab nlist_64 array out of range")
      }
      for i in 0..<nsyms {
        let n = data.withUnsafeBytes {
          $0.load(fromByteOffset: symBase + i * stride, as: nlist_64.self)
        }
        let strx = Int(n.n_un.n_strx)
        guard strx > 0, strBase + strx < strEnd else { continue }
        let nameOff = strBase + strx
        if let name = readCStringInRange(data: data, offset: nameOff, limit: strEnd) {
          out.append(MachOSymbol(name: name, vmAddress: n.n_value))
        }
      }
    } else {
      let stride = MemoryLayout<nlist>.size
      guard symBase + stride * nsyms <= data.count else {
        throw MachOAuditError.malformed(path, "symtab nlist array out of range")
      }
      for i in 0..<nsyms {
        let n = data.withUnsafeBytes {
          $0.load(fromByteOffset: symBase + i * stride, as: nlist.self)
        }
        let strx = Int(n.n_un.n_strx)
        guard strx > 0, strBase + strx < strEnd else { continue }
        let nameOff = strBase + strx
        if let name = readCStringInRange(data: data, offset: nameOff, limit: strEnd) {
          out.append(MachOSymbol(name: name, vmAddress: UInt64(n.n_value)))
        }
      }
    }
  }

  private static func readCStringInRange(data: Data, offset: Int, limit: Int) -> String? {
    guard offset >= 0, offset < limit else { return nil }
    return data.withUnsafeBytes { raw -> String? in
      let base = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
      var len = 0
      while offset + len < limit && base.advanced(by: len).pointee != 0 { len += 1 }
      return String(decoding: UnsafeBufferPointer(start: base, count: len),
                    as: UTF8.self)
    }
  }
}

// ==== ---------------------------------------------------------------------
// MARK: Data helpers

private extension Data {
  func load<T>(_: T.Type, at offset: Int) -> T {
    withUnsafeBytes { $0.load(fromByteOffset: offset, as: T.self) }
  }
}

// The Darwin OSSwap prototypes vary by SDK; use the compiler builtins.
@inline(__always)
private func _OSSwapInt32(_ x: UInt32) -> UInt32 { x.byteSwapped }
@inline(__always)
private func _OSSwapInt64(_ x: UInt64) -> UInt64 { x.byteSwapped }

#endif  // canImport(MachO)
