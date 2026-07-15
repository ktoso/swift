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

// Mach-O backend for the platform-neutral distributed-validation audit
// walker in `SwiftInspectAudit`. See that file for the ABI decoded here.

#if canImport(MachO)

import Foundation
import SwiftInspectAudit

extension MachOFile: AuditImageReader {
  public var pathLabel: String { path }

  public func accessibleFunctionsSection() -> AuditSection? {
    guard let s = findSection(segment: "__TEXT",
                              section: "__swift5_acfuncs") else {
      return nil
    }
    return AuditSection(label: "__TEXT,__swift5_acfuncs",
                        fileOffset: s.fileOffset,
                        vmAddress: s.vmAddress, size: s.size)
  }

  public func davalSection() -> AuditSection? {
    guard let s = findSection(segment: "__DATA_CONST",
                              section: "__swift5_daval") else {
      return nil
    }
    return AuditSection(label: "__DATA_CONST,__swift5_daval",
                        fileOffset: s.fileOffset,
                        vmAddress: s.vmAddress, size: s.size)
  }

  public func descriptionSection() -> AuditSection? {
    // The macro emits the policy-description peer as a UInt8 tuple placed
    // in __TEXT,__cstring, which the linker coalesces with the rest of
    // the process's cstring pool.
    guard let s = findSection(segment: "__TEXT",
                              section: "__cstring") else {
      return nil
    }
    return AuditSection(label: "__TEXT,__cstring",
                        fileOffset: s.fileOffset,
                        vmAddress: s.vmAddress, size: s.size)
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

#endif  // canImport(MachO)
