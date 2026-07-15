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

// CLI wrapper around `MachOFile.auditDistributedValidation()`. The actual
// ABI walk lives in the SwiftInspectMachO library so it can be unit-tested
// without spawning the swift-inspect binary.

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)

import ArgumentParser
import Foundation
import Runtime
import SwiftInspectMachO

/// Grouping command so users type `swift-inspect distributed audit ...`.
internal struct Distributed: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "distributed",
    abstract: "Inspect distributed-actor metadata in a Swift binary.",
    subcommands: [
      Audit.self
    ]
  )
}

internal struct Audit: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "audit",
    abstract: "List distributed methods and their attached remote-call validation")

  @Argument(help: "Path to a Mach-O binary (dylib, executable, or object)")
  var binaryPath: String

  @Option(help: "The arch slice to inspect, e.g. arm64, x86_64")
  var arch: String? = nil

  @Flag(help: "Demangle the thunk names (macOS 27.0+; raw mangled by default)")
  var demangle: Bool = false

  func run() throws {
    let file: MachOFile
    do {
      file = try MachOFile(path: binaryPath, arch: arch)
    } catch {
      throw ValidationError("\(error)")
    }

    let entries: [DistributedAuditEntry]
    do {
      entries = try file.auditDistributedValidation()
    } catch {
      throw ValidationError("\(error)")
    }

    // Only distributed accessible functions are audit-relevant. A record
    // with `isDistributed == false` would be some other kind of accessible
    // function (the compiler doesn't currently emit any); skip those.
    let distributed = entries.filter { $0.isDistributed }
    if distributed.isEmpty {
      print("no distributed accessible functions in \(binaryPath)")
      return
    }
    printTable(entries: distributed)
  }

  private func printTable(entries: [DistributedAuditEntry]) {
    // Present in stable order: entries with validators first (they are the
    // audit-interesting ones), then the rest alphabetically.
    let sorted = entries.sorted { a, b in
      if a.hasValidation != b.hasValidation { return a.hasValidation }
      return a.mangledName < b.mangledName
    }

    let withV = sorted.filter { $0.hasValidation }.count
    print("Distributed accessible functions in \(binaryPath):")
    print("      total: \(sorted.count)")
    print("  validated: \(withV)")
    print("")

    let names = sorted.map { display(for: $0) }
    let nameColWidth = max(40, names.map { $0.count }.max() ?? 40)
    print("  " + "func/var".padding(toLength: nameColWidth,
                                     withPad: " ", startingAt: 0)
          + "  Validators")
    print("  " + String(repeating: "-", count: nameColWidth + 14))
    for (row, e) in zip(names, sorted) {
      let vlist: String
      if e.validatorSymbols.isEmpty {
        vlist = "-"
      } else {
        let symbols = e.validatorSymbols.map { $0 ?? "<stripped>" }
        vlist = "\(symbols.count)  (\(symbols.joined(separator: ", ")))"
      }
      print("  "
            + row.padding(toLength: nameColWidth, withPad: " ", startingAt: 0)
            + "  " + vlist)
    }
  }

  private func display(for entry: DistributedAuditEntry) -> String {
    guard demangle else { return entry.mangledName }
    if #available(macOS 27.0, iOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
      return (try? Runtime.demangle(entry.mangledName)) ?? entry.mangledName
    }
    return entry.mangledName
  }
}

#endif  // Darwin
