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
import SwiftInspectAudit
import SwiftInspectMachO

final class DistributedValidationAuditTests: XCTestCase {

  // ==== -------------------------------------------------------------------
  // MARK: Section reader

  func testSectionAndSymbolEnumeration() throws {
    var fixture = SyntheticMachO()
    let file = try fixture.write().open()

    // Every section we care about is present, at the expected offsets.
    let acf = try XCTUnwrap(file.findSection(segment: "__TEXT",
                                             section: "__swift5_acfuncs"))
    XCTAssertEqual(acf.size,
                   fixture.acfuncsRecords.count *
                   DistributedAuditABI.accessibleFunctionRecordSize)

    let daval = try XCTUnwrap(file.findSection(segment: "__DATA_CONST",
                                               section: "__swift5_daval"))
    let totalValidators = fixture.acfuncsRecords
      .filter(\.hasValidation)
      .flatMap(\.validatorAccessorIndices)
      .count
    XCTAssertEqual(daval.size,
                   totalValidators * DistributedAuditABI.davalRecordSize)

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
      AcfuncsRecord(mangledName: "$s6bank/pingF",
                    isDistributed: true, hasValidation: false,
                    validatorAccessorIndices: [])
    ]

    let file = try fixture.write().open()
    let entries = try file.auditDistributedValidation()
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries[0].mangledName, "$s6bank/pingF")
    XCTAssertTrue(entries[0].isDistributed)
    XCTAssertFalse(entries[0].hasValidation)
    XCTAssertTrue(entries[0].validators.isEmpty)
  }

  func testAudit_singleValidator_resolvesToItsAccessorSymbol() throws {
    var fixture = SyntheticMachO()
    fixture.acfuncsRecords = [
      AcfuncsRecord(mangledName: "$s6bank/transferF",
                    isDistributed: true, hasValidation: true,
                    validatorAccessorIndices: [0])
    ]
    let entries = try fixture.write().open().auditDistributedValidation()
    XCTAssertEqual(entries.count, 1)
    XCTAssertTrue(entries[0].hasValidation)
    XCTAssertEqual(entries[0].validators.map(\.accessorSymbol),
                   ["_daval_transfer_accessor_0"])
    // Default accessor names carry no `fMp` peer marker, so no policy text
    // is resolved even though a `_desc` symbol lookup would fire.
    XCTAssertEqual(entries[0].validators.map(\.policyText), [nil])
  }

  func testAudit_multipleValidators_walkedInListOrder() throws {
    var fixture = SyntheticMachO()
    fixture.acfuncsRecords = [
      AcfuncsRecord(mangledName: "$s6bank/exportAllF",
                    isDistributed: true, hasValidation: true,
                    validatorAccessorIndices: [0, 1, 2])
    ]
    let entries = try fixture.write().open().auditDistributedValidation()
    XCTAssertEqual(entries[0].validators.map(\.accessorSymbol), [
      "_daval_transfer_accessor_0",
      "_daval_transfer_accessor_1",
      "_daval_transfer_accessor_2",
    ])
  }

  func testAudit_mixOfValidatedAndPlain_returnsPerRecordCorrectly() throws {
    var fixture = SyntheticMachO()
    fixture.acfuncsRecords = [
      AcfuncsRecord(mangledName: "$s6bank/aF", isDistributed: true,
                    hasValidation: false, validatorAccessorIndices: []),
      AcfuncsRecord(mangledName: "$s6bank/bF", isDistributed: true,
                    hasValidation: true, validatorAccessorIndices: [1]),
      AcfuncsRecord(mangledName: "$s6bank/cF", isDistributed: true,
                    hasValidation: true, validatorAccessorIndices: [0, 2]),
    ]
    let entries = try fixture.write().open().auditDistributedValidation()
    XCTAssertEqual(entries.count, 3)
    XCTAssertEqual(entries[0].validators.map(\.accessorSymbol), [])
    XCTAssertEqual(entries[1].validators.map(\.accessorSymbol),
                   ["_daval_transfer_accessor_1"])
    XCTAssertEqual(entries[2].validators.map(\.accessorSymbol),
                   ["_daval_transfer_accessor_0", "_daval_transfer_accessor_2"])
  }

  // ==== -------------------------------------------------------------------
  // MARK: Policy text (`_desc` peers)

  /// The compiler emits a `<accessor>_desc` peer symbol whose value points
  /// at a nul-terminated policy source string in the cstring section. The
  /// walker resolves it via `auditAttributeTag(inMangledSymbol:)`, which
  /// stops at the `_` after the `fMp` peer-macro marker in the accessor's
  /// mangled name and looks up any symbol carrying the same tag plus
  /// `_desc`. Real compiler-emitted names look like:
  ///
  ///   `$s...C<method>11EntitlementfMp_25__daval_<method>_accessorfMu_`
  ///
  /// so the tag is the Swift-mangled prefix through `fMp_`; the discriminator
  /// (`__daval_..._accessorfMu_`) sits after and is unique per expansion.
  func testAudit_policyText_isResolvedFromCompanionDescSymbol() throws {
    var fixture = SyntheticMachO()
    fixture.accessors = [
      .init(mangledName: "$s4bank4BankC8transferF11EntitlementfMp_25__daval_transfer_accessorfMu_",
            policyText: "@Entitlement(\"com.example.transfer\")")
    ]
    fixture.acfuncsRecords = [
      AcfuncsRecord(mangledName: "$s6bank/transferF",
                    isDistributed: true, hasValidation: true,
                    validatorAccessorIndices: [0])
    ]
    let entries = try fixture.write().open().auditDistributedValidation()
    XCTAssertEqual(entries[0].validators.count, 1)
    XCTAssertEqual(entries[0].validators[0].policyText,
                   "@Entitlement(\"com.example.transfer\")")
    XCTAssertEqual(entries[0].validators[0].accessorSymbol,
                   "$s4bank4BankC8transferF11EntitlementfMp_25__daval_transfer_accessorfMu_")
  }

  /// Multiple validators on the same thunk each get their own `_desc`,
  /// looked up per-attribute via the peer-macro tag. The attribute-name
  /// segment (`11Entitlement`, `18ValidateRemoteCall`) sits BEFORE `fMp_`,
  /// so `auditAttributeTag` produces a distinct tag per validator and the
  /// walker's substring match resolves to the correct `_desc` sibling.
  func testAudit_stackedValidators_eachResolvesItsOwnPolicyText() throws {
    var fixture = SyntheticMachO()
    fixture.accessors = [
      .init(mangledName: "$s4home5HomeC8openDoorF11EntitlementfMp_25__daval_openDoor_accessorfMu_",
            policyText: "@Entitlement(.anyOf([\"admin\", \"superuser\"]))"),
      .init(mangledName: "$s4home5HomeC8openDoorF18ValidateRemoteCallfMp_25__daval_openDoor_accessorfMu_",
            policyText: "@ValidateRemoteCall(callerIsBankOfficer)"),
    ]
    fixture.acfuncsRecords = [
      AcfuncsRecord(mangledName: "$s4home5HomeC8openDoorF",
                    isDistributed: true, hasValidation: true,
                    validatorAccessorIndices: [0, 1])
    ]
    let entries = try fixture.write().open().auditDistributedValidation()
    let policies = entries[0].validators.map(\.policyText)
    XCTAssertEqual(policies, [
      "@Entitlement(.anyOf([\"admin\", \"superuser\"]))",
      "@ValidateRemoteCall(callerIsBankOfficer)",
    ])
  }

  /// A validator whose accessor has NO `_desc` peer is still reported; the
  /// audit entry just gets `policyText: nil` for it (default output collapses
  /// these; `--verbose` restores them). Simulates a binary built with
  /// `SWIFT_DISTRIBUTED_VALIDATE_RETAIN_DESCRIPTION_IN_BINARY=0`.
  func testAudit_mixedValidators_reportsNilPolicyForMissingDesc() throws {
    var fixture = SyntheticMachO()
    fixture.accessors = [
      .init(mangledName: "$s4bank4BankC6chargeF11EntitlementfMp_23__daval_charge_accessorfMu_",
            policyText: "@Entitlement(\"com.example.charge\")"),
      .init(mangledName: "$s4bank4BankC6chargeF18ValidateRemoteCallfMp_23__daval_charge_accessorfMu_",
            policyText: nil),
    ]
    fixture.acfuncsRecords = [
      AcfuncsRecord(mangledName: "$s6bank/chargeF",
                    isDistributed: true, hasValidation: true,
                    validatorAccessorIndices: [0, 1])
    ]
    let entries = try fixture.write().open().auditDistributedValidation()
    XCTAssertEqual(entries[0].validators.map(\.policyText), [
      "@Entitlement(\"com.example.charge\")",
      nil,
    ])
  }

  // ==== -------------------------------------------------------------------
  // MARK: JSON encoding

  /// The audit types conform to `Codable` so the CLI's `--format=json` mode
  /// can emit machine-readable output. This test pins the encoded shape
  /// (field names, nested arrays, elided optionals) so downstream scripting
  /// against the JSON has a stable contract.
  func testAudit_jsonEncoding_hasStableFieldNames() throws {
    let entries: [DistributedAuditEntry] = [
      DistributedAuditEntry(
        mangledName: "$s6bank/transferF",
        isDistributed: true, hasValidation: true,
        validators: [
          DistributedValidator(
            accessorSymbol: "_daval_transfer_accessor_ent_fMp_",
            policyText: "@Entitlement(\"com.example.transfer\")"),
          DistributedValidator(
            accessorSymbol: "_daval_transfer_accessor_vrc_fMp_",
            policyText: nil),
        ]),
      DistributedAuditEntry(
        mangledName: "$s6bank/pingF",
        isDistributed: true, hasValidation: false, validators: []),
    ]

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(entries)
    let text = try XCTUnwrap(String(data: data, encoding: .utf8))

    // Field names + basic values match the CLI contract.
    XCTAssertTrue(text.contains("\"mangledName\":\"$s6bank/transferF\""),
                  text)
    XCTAssertTrue(text.contains("\"hasValidation\":true"), text)
    XCTAssertTrue(text.contains("\"hasValidation\":false"), text)
    XCTAssertTrue(text.contains("\"policyText\":\"@Entitlement(\\\"com.example.transfer\\\")\""),
                  text)
    // A `nil` optional serializes as an absent key -- avoid a bare `null`
    // in the output so consumers can treat missing == absent.
    XCTAssertFalse(text.contains("\"policyText\":null"), text)
    XCTAssertFalse(text.contains("\"accessorSymbol\":null"), text)

    // Round-trip: decode goes back to the same shape (Codable symmetry).
    let decoded = try JSONDecoder().decode([DistributedAuditEntry].self,
                                            from: data)
    XCTAssertEqual(decoded, entries)
  }

  // ==== -------------------------------------------------------------------
  // MARK: Edge / error paths

  func testAudit_binaryWithoutAcfuncsSection_returnsEmpty() throws {
    // We can't easily produce a Mach-O with NO __swift5_acfuncs via the
    // fixture (it always emits the section). Simulate by zeroing acfuncs
    // records; the walker treats an empty section as "no accessible
    // functions" and returns an empty list without touching daval.
    var fixture = SyntheticMachO()
    fixture.acfuncsRecords = []
    let entries = try fixture.write().open().auditDistributedValidation()
    XCTAssertTrue(entries.isEmpty)
  }

  func testAudit_strippedAccessorSymbol_isReportedAsNil() throws {
    var fixture = SyntheticMachO()
    fixture.acfuncsRecords = [
      AcfuncsRecord(mangledName: "$s6bank/pF", isDistributed: true,
                    hasValidation: true, validatorAccessorIndices: [0])
    ]
    fixture.stripAccessorSymbols = true
    let entries = try fixture.write().open().auditDistributedValidation()
    XCTAssertEqual(entries[0].validators.map(\.accessorSymbol), [nil])
  }

  func testAudit_acfuncsSizeNotMultipleOfRecordSize_throws() throws {
    var fixture = SyntheticMachO()
    let file = try fixture.write().open()
    // Corrupt the on-disk file by rewriting the __swift5_acfuncs section
    // size in the section_64 header so it's non-multiple of the record
    // size (20 bytes). `+3` guarantees non-multiple regardless of the base.
    let bad = SyntheticMachO.corruptAcfuncsSize(from: file.path, by: 3)
    let badFile = try MachOFile(path: bad)
    XCTAssertThrowsError(try badFile.auditDistributedValidation()) { err in
      guard case DistributedAuditError.acfuncsSizeNotMultiple = err else {
        return XCTFail("expected acfuncsSizeNotMultiple, got \(err)")
      }
    }
  }

  /// A daval linked-list that never terminates should trip the safety cap
  /// (`davalListMaxLength`) rather than spinning forever. Emulate by
  /// requesting 1025 stacked validators (walker cap is 1024) and confirm the
  /// error surfaces from the walker.
  func testAudit_runawayDavalList_throwsSafely() throws {
    var fixture = SyntheticMachO()
    fixture.accessors = (0..<1025).map { i in
      .init(mangledName: "_daval_test_accessor_\(i)", policyText: nil)
    }
    fixture.acfuncsRecords = [
      AcfuncsRecord(mangledName: "$s4test/runawayF",
                    isDistributed: true, hasValidation: true,
                    validatorAccessorIndices: Array(0..<1025))
    ]
    let file = try fixture.write().open()
    XCTAssertThrowsError(try file.auditDistributedValidation()) { err in
      guard case DistributedAuditError.runawayDavalList = err else {
        return XCTFail("expected runawayDavalList, got \(err)")
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
