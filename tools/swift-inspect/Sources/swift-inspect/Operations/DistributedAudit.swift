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

  @Flag(name: [.short, .long],
        help: ArgumentHelp("Show every validator, including entries with no "
                            + "policy text (which get the raw accessor "
                            + "symbol name instead)"))
  var verbose: Bool = false

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
      if e.validators.isEmpty {
        vlist = "-"
      } else {
        // Default view: only show validators the compiler preserved policy
        // source text for. Bare accessor symbol names (a mangled dylib
        // symbol like `_$s...__daval_transfer_accessor...`) are noise for
        // the common case; hide them unless the user asks with --verbose.
        let items = e.validators.compactMap { v -> String? in
          if let text = v.policyText { return text }
          if verbose { return v.accessorSymbol ?? "<stripped>" }
          return nil
        }
        if items.isEmpty {
          // Every validator lacks policy text and we're not verbose.
          // Show the count so the user knows there ARE validators; details
          // are one --verbose away.
          vlist = "\(e.validators.count)  --verbose to show"
        } else {
          vlist = "\(items.count)  \(items.joined(separator: ", "))"
        }
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
