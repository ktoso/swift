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

#if canImport(MachO)

import XCTest
import MachO
@testable import SwiftInspectMachO

final class DistributedValidationAuditTests: XCTestCase {

  // ==== -------------------------------------------------------------------
  // MARK: Section reader

  func testSectionAndSymbolEnumeration() throws {
    let fixture = SyntheticMachO()
    let file = try fixture.write().open()

    // Every section we care about is present, at the expected offsets.
    let acf = try XCTUnwrap(file.findSection(segment: "__TEXT",
                                             section: "__swift5_acfuncs"))
    XCTAssertEqual(acf.size,
                   fixture.acfuncsRecords.count *
                   DistributedAuditABI.accessibleFunctionRecordSize)

    let daval = try XCTUnwrap(file.findSection(segment: "__DATA_CONST",
                                               section: "__swift5_daval"))
    XCTAssertEqual(daval.size,
                   fixture.davalRecords.count *
                   DistributedAuditABI.davalRecordSize)

    let davala = try XCTUnwrap(file.findSection(segment: "__DATA_CONST",
                                                section: "__swift5_davala"))
    XCTAssertEqual(davala.size, fixture.accessorVMSlots * 8)

    // Symbol table round-trips.
    for (vm, name) in fixture.accessorSymbolsByVM {
      XCTAssertEqual(file.symbolsByVMAddress[vm], name,
                     "symbol at VM \(String(vm, radix: 16)) should be \(name)")
    }
  }

  // ==== -------------------------------------------------------------------
  // MARK: Happy path

  func testAudit_thunkWithoutValidation_isReportedButHasNoValidators() throws {
    var fixture = SyntheticMachO()
    fixture.acfuncsRecords = [
      .init(mangledName: "$s6bank/pingF",
            isDistributed: true, hasValidation: false,
            validatorAccessorIndices: [])
    ]
    fixture.davalRecords = []

    let file = try fixture.write().open()
    let entries = try file.auditDistributedValidation()
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries[0].mangledName, "$s6bank/pingF")
    XCTAssertTrue(entries[0].isDistributed)
    XCTAssertFalse(entries[0].hasValidation)
    XCTAssertTrue(entries[0].validatorSymbols.isEmpty)
  }

  func testAudit_singleValidator_resolvesToItsAccessorSymbol() throws {
    var fixture = SyntheticMachO()
    fixture.acfuncsRecords = [
      .init(mangledName: "$s6bank/transferF",
            isDistributed: true, hasValidation: true,
            validatorAccessorIndices: [0])
    ]
    let entries = try fixture.write().open().auditDistributedValidation()
    XCTAssertEqual(entries.count, 1)
    XCTAssertTrue(entries[0].hasValidation)
    XCTAssertEqual(entries[0].validatorSymbols, ["_daval_transfer_accessor_0"])
  }

  func testAudit_multipleValidators_walkedInListOrder() throws {
    var fixture = SyntheticMachO()
    fixture.acfuncsRecords = [
      .init(mangledName: "$s6bank/exportAllF",
            isDistributed: true, hasValidation: true,
            validatorAccessorIndices: [0, 1, 2])
    ]
    let entries = try fixture.write().open().auditDistributedValidation()
    XCTAssertEqual(entries[0].validatorSymbols, [
      "_daval_transfer_accessor_0",
      "_daval_transfer_accessor_1",
      "_daval_transfer_accessor_2",
    ])
  }

  func testAudit_mixOfValidatedAndPlain_returnsPerRecordCorrectly() throws {
    var fixture = SyntheticMachO()
    fixture.acfuncsRecords = [
      .init(mangledName: "$s6bank/aF", isDistributed: true,
            hasValidation: false, validatorAccessorIndices: []),
      .init(mangledName: "$s6bank/bF", isDistributed: true,
            hasValidation: true, validatorAccessorIndices: [1]),
      .init(mangledName: "$s6bank/cF", isDistributed: true,
            hasValidation: true, validatorAccessorIndices: [0, 2]),
    ]
    let entries = try fixture.write().open().auditDistributedValidation()
    XCTAssertEqual(entries.count, 3)
    XCTAssertEqual(entries[0].validatorSymbols, [])
    XCTAssertEqual(entries[1].validatorSymbols,
                   ["_daval_transfer_accessor_1"])
    XCTAssertEqual(entries[2].validatorSymbols,
                   ["_daval_transfer_accessor_0", "_daval_transfer_accessor_2"])
  }

  // ==== -------------------------------------------------------------------
  // MARK: Edge / error paths

  func testAudit_binaryWithoutAcfuncsSection_returnsEmpty() throws {
    var fixture = SyntheticMachO()
    fixture.acfuncsRecords = []
    fixture.davalRecords = []
    let entries = try fixture.write().open().auditDistributedValidation()
    XCTAssertTrue(entries.isEmpty)
  }

  func testAudit_strippedAccessorSymbol_isReportedAsNil() throws {
    var fixture = SyntheticMachO()
    fixture.acfuncsRecords = [
      .init(mangledName: "$s6bank/pF", isDistributed: true,
            hasValidation: true, validatorAccessorIndices: [0])
    ]
    fixture.stripAccessorSymbols = true
    let entries = try fixture.write().open().auditDistributedValidation()
    XCTAssertEqual(entries[0].validatorSymbols, [nil])
  }

  func testAudit_acfuncsSizeNotMultipleOfRecordSize_throws() throws {
    let fixture = SyntheticMachO()
    let file = try fixture.write().open()
    // Corrupt the on-disk file by rewriting the __swift5_acfuncs section size
    // in the section_64 header so it's non-multiple. Easier: rewrite the
    // section on-disk via a second fixture with tweaked size.
    let bad = SyntheticMachO.corruptAcfuncsSize(from: file.path, by: 3)
    let badFile = try MachOFile(path: bad)
    XCTAssertThrowsError(try badFile.auditDistributedValidation()) { err in
      guard case DistributedAuditError.acfuncsSizeNotMultiple = err else {
        return XCTFail("expected acfuncsSizeNotMultiple, got \(err)")
      }
    }
  }

  // ==== -------------------------------------------------------------------
  // MARK: ABI constants sanity

  /// Guard against silent drift of the ABI constants that the offline
  /// reader depends on. If any of these change on the compiler side,
  /// the audit tool must be updated in lock-step.
  func testABIConstantsMatchCompilerEmittedShape() {
    XCTAssertEqual(DistributedAuditABI.accessibleFunctionRecordSize, 20)
    XCTAssertEqual(DistributedAuditABI.flagsFieldOffset, 16)
    XCTAssertEqual(DistributedAuditABI.flagIsDistributed, 0x1)
    XCTAssertEqual(DistributedAuditABI.flagHasValidation, 0x2)
    XCTAssertEqual(DistributedAuditABI.flagTagMask, 0x3)
    XCTAssertEqual(DistributedAuditABI.davalRecordSize, 16)
    XCTAssertEqual(DistributedAuditABI.davalAccessorFieldOffset, 8)
    XCTAssertEqual(DistributedAuditABI.davalNextFieldOffset, 12)
    // FourCC 'dval' in little-endian byte order.
    XCTAssertEqual(DistributedAuditABI.davalKindValidation, 0x6476616c)
  }
}

#endif  // canImport(MachO)
