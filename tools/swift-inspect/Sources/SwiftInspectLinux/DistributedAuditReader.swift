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

// ELF backend for the platform-neutral distributed-validation audit walker
// in `SwiftInspectAudit`. Section names come from IRGen (see
// `lib/IRGen/GenDecl.cpp:getDistributedValidationSectionName` and
// `IRGenModule::emitAccessibleFunctions`):
//
//   accessible-function records:   `swift5_accessible_functions`
//   validation records:            `swift5_daval`
//   validation accessors:          `swift5_davala`
//   policy-description peers:      `swift5_davala_desc`
//
// The description peers land in their own section on ELF because ELF has
// no equivalent of Mach-O's `__TEXT,__cstring` cstring-pool coalescing.

#if os(Linux) || os(Android)

import Foundation
import LinuxSystemHeaders
import SwiftInspectAudit

/// Wraps an `ElfFile` in the `AuditImageReader` protocol so the
/// platform-neutral walker can consume it.
public final class ElfDistributedAuditReader: AuditImageReader {
  public let elf: ElfFile
  public let path: String

  private let sectionsByName: [String: ElfFile.SectionInfo]
  private let symbolsByVMAddress: [UInt64: String]
  private let symbolsByName: [String: UInt64]

  public init(elf: ElfFile) throws {
    self.elf = elf
    self.path = elf.filePath
    let sections = try elf.loadSections()
    var byName: [String: ElfFile.SectionInfo] = [:]
    byName.reserveCapacity(sections.count)
    for s in sections where byName[s.name] == nil {
      byName[s.name] = s
    }
    self.sectionsByName = byName

    let symbols = try elf.loadSymbols(baseAddress: 0)
    var byAddr: [UInt64: String] = [:]
    var symByName: [String: UInt64] = [:]
    byAddr.reserveCapacity(symbols.count)
    symByName.reserveCapacity(symbols.count)
    for (name, range) in symbols {
      let vm = range.start
      if vm != 0, byAddr[vm] == nil {
        byAddr[vm] = name
      }
      if symByName[name] == nil {
        symByName[name] = vm
      }
    }
    self.symbolsByVMAddress = byAddr
    self.symbolsByName = symByName
  }

  public var pathLabel: String { path }

  public func accessibleFunctionsSection() -> AuditSection? {
    section("swift5_accessible_functions")
  }

  public func davalSection() -> AuditSection? {
    section("swift5_daval")
  }

  public func descriptionSection() -> AuditSection? {
    section("swift5_davala_desc")
  }

  private func section(_ name: String) -> AuditSection? {
    guard let s = sectionsByName[name] else { return nil }
    return AuditSection(label: name,
                        fileOffset: s.fileOffset,
                        vmAddress: s.vmAddress,
                        size: s.size)
  }

  public func readCString(atFileOffset off: Int) -> String? {
    elf.readCString(atFileOffset: off)
  }

  public func readInt32(atFileOffset off: Int) -> Int32? {
    elf.readInt32(atFileOffset: off)
  }

  public func readUInt32(atFileOffset off: Int) -> UInt32? {
    elf.readUInt32(atFileOffset: off)
  }

  public func symbolName(atVMAddress vm: UInt64) -> String? {
    symbolsByVMAddress[vm]
  }

  public func forEachSymbol(_ body: (_ name: String, _ vm: UInt64) -> Void) {
    for (name, vm) in symbolsByName {
      body(name, vm)
    }
  }
}

#endif  // os(Linux) || os(Android)
