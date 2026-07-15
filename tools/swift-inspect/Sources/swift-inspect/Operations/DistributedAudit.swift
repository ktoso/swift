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

// CLI wrapper around the platform-neutral `AuditImageReader` walker in
// `SwiftInspectAudit`. Dispatches to a Mach-O backend on Darwin and an
// ELF backend on Linux/Android.

import ArgumentParser
import Foundation
import SwiftInspectAudit
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
import Runtime
import SwiftInspectMachO
#elseif os(Linux) || os(Android)
import SwiftInspectLinux
#endif

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

/// JSON row used only when `--format=json --demangle` is set: same shape
/// as `DistributedAuditEntry` plus a `demangledName` field. Kept out of
/// `SwiftInspectAudit` because demangling is a CLI concern that varies by
/// platform (Runtime.demangle on macOS 27+, nothing on Linux for now).
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
private struct AuditEntryWithDemangled: Encodable {
  var mangledName: String
  var demangledName: String
  var isDistributed: Bool
  var hasValidation: Bool
  var validators: [DistributedValidator]
}
#endif

internal struct Audit: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "audit",
    abstract: "List distributed methods and their attached remote-call validation")

  enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
    case text
    case json
  }

  @Argument(help: "Path to a binary (dylib/so, executable, or object)")
  var binaryPath: String

  #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
  @Option(help: "The arch slice to inspect, e.g. arm64, x86_64")
  var arch: String? = nil

  @Flag(help: "Demangle the thunk names (macOS 27.0+; raw mangled by default)")
  var demangle: Bool = false
  #endif

  @Flag(name: [.short, .long],
        help: ArgumentHelp("Show every validator, including entries with no "
                            + "policy text (which get the raw accessor "
                            + "symbol name instead)"))
  var verbose: Bool = false

  @Option(name: [.long],
          help: ArgumentHelp("Output format: `text` (default) or `json`. "
                              + "JSON emits every entry -- --verbose is a "
                              + "text-mode filter and has no effect on JSON."))
  var format: OutputFormat = .text

  func run() throws {
    let reader: AuditImageReader
    do {
      reader = try openReader(for: binaryPath)
    } catch {
      throw ValidationError("\(error)")
    }

    let entries: [DistributedAuditEntry]
    do {
      entries = try reader.auditDistributedValidation()
    } catch {
      throw ValidationError("\(error)")
    }

    // Only distributed accessible functions are audit-relevant. A record
    // with `isDistributed == false` would be some other kind of accessible
    // function (the compiler doesn't currently emit any); skip those.
    let distributed = entries.filter { $0.isDistributed }

    switch format {
    case .text:
      if distributed.isEmpty {
        print("no distributed accessible functions in \(binaryPath)")
        return
      }
      printTable(entries: distributed)
    case .json:
      try printJSON(entries: distributed)
    }
  }

  private func openReader(for path: String) throws -> AuditImageReader {
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    return try MachOFile(path: path, arch: arch)
    #elseif os(Linux) || os(Android)
    let elf = try ElfFile(filePath: path)
    return try ElfDistributedAuditReader(elf: elf)
    #else
    throw ValidationError("`distributed audit` is not implemented on this platform")
    #endif
  }

  /// Sort audit entries in a stable, human-friendly order shared between
  /// text and JSON output: entries with validators first (the audit-
  /// interesting ones), then the rest alphabetically by mangled name.
  /// Keeping this in one place so `diff`ing text vs JSON of the same
  /// binary reveals only formatting differences, not row-ordering ones.
  private func stableSorted(_ entries: [DistributedAuditEntry]) -> [DistributedAuditEntry] {
    entries.sorted { a, b in
      if a.hasValidation != b.hasValidation { return a.hasValidation }
      return a.mangledName < b.mangledName
    }
  }

  /// Emit the audit entries as JSON on stdout. The output is a JSON array
  /// of `DistributedAuditEntry` objects; each entry contains `mangledName`,
  /// `demangledName` (only when `--demangle` is passed on macOS 27+),
  /// `isDistributed`, `hasValidation`, and `validators` (each with
  /// `accessorSymbol` and `policyText`, either of which may be missing).
  /// Keys are sorted so diffing two audits is meaningful; encoding is
  /// pretty-printed.
  private func printJSON(entries: [DistributedAuditEntry]) throws {
    let sorted = stableSorted(entries)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    let data: Data
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    if demangle {
      let rows = sorted.map { e in
        AuditEntryWithDemangled(
          mangledName: e.mangledName,
          demangledName: display(for: e),
          isDistributed: e.isDistributed,
          hasValidation: e.hasValidation,
          validators: e.validators)
      }
      data = try encoder.encode(rows)
    } else {
      data = try encoder.encode(sorted)
    }
    #else
    data = try encoder.encode(sorted)
    #endif

    if let text = String(data: data, encoding: .utf8) {
      print(text)
    }
  }

  private func printTable(entries: [DistributedAuditEntry]) {
    let sorted = stableSorted(entries)

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
        let items = e.validators.compactMap { v -> String? in
          if let text = v.policyText { return text }
          if verbose { return v.accessorSymbol ?? "<stripped>" }
          return nil
        }
        if items.isEmpty {
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
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    guard demangle else { return entry.mangledName }
    if #available(macOS 27.0, iOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
      return (try? Runtime.demangle(entry.mangledName)) ?? entry.mangledName
    }
    return entry.mangledName
    #else
    // Linux: no in-process demangling API on this branch yet. Raw name.
    return entry.mangledName
    #endif
  }
}
