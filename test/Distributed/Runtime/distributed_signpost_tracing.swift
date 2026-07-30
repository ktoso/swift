// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems -target %target-future-triple %S/../Inputs/FakeDistributedActorSystems.swift
// RUN: %target-build-swift -module-name main -target %target-future-triple -j2 -parse-as-library -I %t %s %S/../Inputs/FakeDistributedActorSystems.swift -o %t/a.out -Onone
// RUN: %target-codesign %t/a.out
// RUN: %target-run %t/a.out

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: distributed
// REQUIRES: OS=macosx
// UNSUPPORTED: use_os_stdlib
// UNSUPPORTED: back_deployment_runtime

// Verify the signposts emitted around a distributed call, and show what a
// trace of one call actually looks like. A 'FakeRoundtripActorSystem' drives
// both sides in this one process, so a single call produces the outbound
// signposts from the thunk and the inbound ones from
// 'executeDistributedTarget'.
//
// Built at -Onone so the optimizer does not eliminate the distributed
// machinery being measured, and against a future triple so the '9999'
// availability guards inside the tracing entry points are satisfied.

import Distributed
import FakeDistributedActorSystems
import Foundation
import os
import StdlibUnittest

typealias DefaultDistributedActorSystem = FakeRoundtripActorSystem

// ==== -----------------------------------------------------------------------
// MARK: Signpost JSON model

/// One NDJSON record from `log stream --style ndjson`
struct LogStreamRecord: Decodable {
  var signpostName: String?
  var signpostType: SignpostType?
  var eventMessage: String?

  enum SignpostType: String, Decodable {
    case begin
    case end
    case event
  }
}

struct SignpostEvent: CustomStringConvertible {
  var name: String
  var type: LogStreamRecord.SignpostType
  var message: String

  var description: String { "\(name) (\(type.rawValue)): \(message)" }
}

/// An expected signpost. A nil `type` matches any type with that name; every
/// string in `messageContains` must appear in the event message.
struct ExpectedSignpost: CustomStringConvertible {
  var name: String
  var type: LogStreamRecord.SignpostType?
  var messageContains: [String] = []

  init(name: String,
       type: LogStreamRecord.SignpostType? = nil,
       messageContains: [String] = []) {
    self.name = name
    self.type = type
    self.messageContains = messageContains
  }

  var description: String {
    var result = name
    if let type { result += " (\(type.rawValue))" }
    if !messageContains.isEmpty {
      result += " [contains: \(messageContains.joined(separator: ", "))]"
    }
    return result
  }

  func matches(_ event: SignpostEvent) -> Bool {
    if name != event.name { return false }
    if let type, type != event.type { return false }
    return messageContains.allSatisfy { event.message.contains($0) }
  }
}

struct TimeoutError: Error, CustomStringConvertible {
  var description: String { "Timed out waiting for signpost events" }
}

// ==== -----------------------------------------------------------------------
// MARK: Signpost monitor

/// Monitors the signposts this process emits on the Distributed subsystem,
/// by streaming them back out of the logging daemon with `log stream`.
class SignpostMonitor {
  private let process: Process
  private let events: AsyncThrowingStream<SignpostEvent, Error>
  private let eventsContinuation: AsyncThrowingStream<SignpostEvent, Error>.Continuation

  /// Must match 'SWIFT_LOG_DISTRIBUTED_SUBSYSTEM' in
  /// stdlib/public/Distributed/TracingDistributedSignpost.cpp
  static let subsystem = "com.apple.swift.distributed"
  private static let canaryName = "signpost_monitor_canary"
  private static let canarySignposter = OSSignposter(
    subsystem: SignpostMonitor.subsystem, category: "TestCanary")

  /// How long to wait for `log stream`'s header banner. The banner needs no
  /// daemon round-trip and appears near-instantly when logging is reachable,
  /// so a short budget lets an unavailable environment bail out quickly.
  private static let headerTimeout: Duration = .seconds(3)

  private let decoder = JSONDecoder()

  /// Every signpost seen, in arrival order; used to print the trace
  private(set) var allEvents: [SignpostEvent] = []

  private init(process: Process,
               events: AsyncThrowingStream<SignpostEvent, Error>,
               continuation: AsyncThrowingStream<SignpostEvent, Error>.Continuation) {
    self.process = process
    self.events = events
    self.eventsContinuation = continuation
  }

  /// Launches `log stream` and waits until it is genuinely live, confirmed by
  /// a canary signpost making the round trip. Returns nil when streaming is
  /// unavailable, e.g. a restricted environment where the spawned `log`
  /// cannot reach the logging daemon; callers then skip verification.
  private static func connect() async -> SignpostMonitor? {
    let pid = ProcessInfo.processInfo.processIdentifier

    let (events, continuation) = AsyncThrowingStream<SignpostEvent, Error>.makeStream()

    let process = Process()
    let pipe = Pipe()

    process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    process.arguments = [
      "stream",
      "--signpost",
      "--predicate",
      "subsystem == \"\(subsystem)\" AND processIdentifier == \(pid)",
      "--style", "ndjson",
    ]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    let monitor = SignpostMonitor(
      process: process, events: events, continuation: continuation)

    // readabilityHandler is not called concurrently, so no locking is needed
    nonisolated(unsafe) var buffer = Data()
    let headerReady = AsyncThrowingStream<Void, Error>.makeStream()

    pipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }

      buffer.append(data)

      while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
        let lineData = buffer[buffer.startIndex..<newlineIndex]
        buffer = buffer[(buffer.index(after: newlineIndex))...]

        guard let line = String(data: lineData, encoding: .utf8) else {
          continue
        }

        // The first line is a header like "Filtering the log data using ..."
        if line.hasPrefix("Filtering") || line.hasPrefix("Timestamp") {
          headerReady.1.finish()
          continue
        }

        monitor.processLine(line)
      }
    }

    do {
      try process.run()
    } catch {
      fatalError("Failed to launch log stream: \(error)")
    }

    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          for try await _ in headerReady.0 {}
        }
        group.addTask {
          try await Task.sleep(for: headerTimeout)
          throw TimeoutError()
        }
        try await group.next()
        group.cancelAll()
      }
    } catch {
      process.terminate()
      return nil
    }

    // The header appears before the stream is fully connected to logd, so
    // emit canary signposts until one comes back
    let canaryStream = AsyncThrowingStream<Void, Error>.makeStream()
    monitor.canaryReady = canaryStream.1

    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          for try await _ in canaryStream.0 {}
        }
        group.addTask {
          while !Task.isCancelled {
            canarySignposter.emitEvent("signpost_monitor_canary")
            try await Task.sleep(for: .milliseconds(100))
          }
        }
        group.addTask {
          try await Task.sleep(for: .seconds(20))
          throw TimeoutError()
        }
        try await group.next()
        group.cancelAll()
      }
    } catch {
      process.terminate()
      return nil
    }
    monitor.canaryReady = nil

    return monitor
  }

  /// Whether `log stream` can be connected here, probed once so that an
  /// unavailable environment does not pay the pre-check per test
  private static var availability: Bool?

  static func start() async -> SignpostMonitor? {
    if availability == false {
      return nil
    }
    let monitor = await connect()
    availability = (monitor != nil)
    return monitor
  }

  private var canaryReady: AsyncThrowingStream<Void, Error>.Continuation?

  private func processLine(_ line: String) {
    guard let data = line.data(using: .utf8),
          let record = try? decoder.decode(LogStreamRecord.self, from: data),
          let name = record.signpostName
    else {
      return
    }

    // Confirms the log stream is fully connected
    if name == SignpostMonitor.canaryName {
      canaryReady?.finish()
      return
    }

    let event = SignpostEvent(
      name: name,
      type: record.signpostType ?? .event,
      message: record.eventMessage ?? ""
    )
    allEvents.append(event)
    eventsContinuation.yield(event)
  }

  /// Waits for all expected signposts to arrive, then prints every signpost
  /// that was seen so the shape of the trace is visible in the test output.
  /// On timeout, reports which ones were missing.
  func expectAllSignpostsReceived(
    _ expected: [ExpectedSignpost],
    timeout: Duration = .seconds(20)
  ) async {
    var remaining = expected

    let timeoutTask = Task.detached { [eventsContinuation] in
      try await Task.sleep(for: timeout)
      eventsContinuation.finish(throwing: TimeoutError())
    }

    do {
      for try await event in events {
        if let idx = remaining.firstIndex(where: { $0.matches(event) }) {
          remaining.remove(at: idx)
          if remaining.isEmpty {
            break
          }
        }
      }
    } catch is TimeoutError {
      // Fall through to report the missing signposts below
    } catch {
      expectTrue(false, "Unexpected error: \(error)")
    }

    timeoutTask.cancel()
    process.terminate()
    process.waitUntilExit()

    print("---- trace ----")
    for event in allEvents {
      print("  \(event)")
    }
    print("---- end trace ----")

    if !remaining.isEmpty {
      var msg = "Missing signposts:\n"
      for m in remaining {
        msg += "  - \(m)\n"
      }
      expectTrue(false, msg)
    }
  }
}

// ==== -----------------------------------------------------------------------
// MARK: Test actor

distributed actor Greeter {
  distributed func greet(name: String) -> String {
    "Hello, \(name)!"
  }

  distributed func boom() throws -> String {
    throw GreeterError.boom
  }
}

enum GreeterError: Error {
  case boom
}

// ==== -----------------------------------------------------------------------
// MARK: Tests

@main struct Main {
  static func main() async {
    var tests = TestSuite("DistributedSignpostTracing")

    // A single remote call produces the whole outbound/inbound sequence:
    //
    //   distributed_outbound_encode_arguments   (begin/end)  caller: encoding
    //   distributed_outbound_remote_call        (event)      caller: dispatch
    //   distributed_inbound_execute_target      (event)      callee: received
    //   distributed_inbound_decode_arguments    (begin/end)  callee: decoding
    //   distributed_inbound_invoke_target       (begin/end)  callee: executing
    //   distributed_inbound_invoke_result_handler (event)    callee: replied
    //
    // 'distributed_inbound_find_accessible_function' also appears, once inside
    // each of the decode and invoke intervals.
    tests.test("RemoteCall/roundtrip") {
      guard let monitor = await SignpostMonitor.start() else {
        print("skipping: signpost log streaming unavailable in this environment")
        return
      }

      let system = DefaultDistributedActorSystem()
      let local = Greeter(actorSystem: system)
      let remote = try! Greeter.resolve(id: local.id, using: system)

      let reply = try! await remote.greet(name: "Caplin")
      expectEqual("Hello, Caplin!", reply)

      // The mangled accessor record name of the target, carried by the
      // outbound event and by both sides' intervals
      let target = "$s4main7GreeterC5greet4nameS2S_tYaKFTE"

      await monitor.expectAllSignpostsReceived(
        // Outbound: the thunk brackets encoding, then dispatches
        [ExpectedSignpost(name: "distributed_outbound_encode_arguments",
                          type: .begin,
                          messageContains: ["targetFunction=\(target)",
                                            "argumentCount=1"]),
         ExpectedSignpost(name: "distributed_outbound_encode_arguments",
                          type: .end, messageContains: ["success=true"]),
         ExpectedSignpost(name: "distributed_outbound_remote_call",
                          type: .event,
                          messageContains: ["targetFunction=\(target)",
                                            "actorType=main.Greeter"]),
         // Inbound: 'executeDistributedTarget' splits decode from execute
         ExpectedSignpost(name: "distributed_inbound_execute_target",
                          type: .event,
                          messageContains: ["targetFunction=\(target)",
                                            "actorType=main.Greeter"]),
         ExpectedSignpost(name: "distributed_inbound_decode_arguments",
                          type: .begin,
                          messageContains: ["targetFunction=\(target)"]),
         ExpectedSignpost(name: "distributed_inbound_decode_arguments",
                          type: .end,
                          messageContains: ["argumentCount=1", "success=true"]),
         ExpectedSignpost(name: "distributed_inbound_invoke_target",
                          type: .begin,
                          messageContains: ["targetFunction=\(target)"]),
         ExpectedSignpost(name: "distributed_inbound_invoke_target",
                          type: .end, messageContains: ["success=true"]),
         ExpectedSignpost(name: "distributed_inbound_invoke_result_handler",
                          type: .event, messageContains: ["success=true"])]
      )
    }

    // A target that throws still closes its intervals, and the result handler
    // event reports that the throwing path was taken
    tests.test("RemoteCall/throwing") {
      guard let monitor = await SignpostMonitor.start() else {
        print("skipping: signpost log streaming unavailable in this environment")
        return
      }

      let system = DefaultDistributedActorSystem()
      let local = Greeter(actorSystem: system)
      let remote = try! Greeter.resolve(id: local.id, using: system)

      do {
        _ = try await remote.boom()
        expectTrue(false, "expected 'boom()' to throw")
      } catch {
        // expected
      }

      await monitor.expectAllSignpostsReceived(
        // The invoke interval still terminates, reporting the failure...
        [ExpectedSignpost(name: "distributed_inbound_invoke_target",
                          type: .end, messageContains: ["success=false"]),
         // ...and the result handler event reports the throwing path
         ExpectedSignpost(name: "distributed_inbound_invoke_result_handler",
                          type: .event, messageContains: ["success=false"]),
         // Encoding still succeeded; only the target itself threw
         ExpectedSignpost(name: "distributed_outbound_encode_arguments",
                          type: .end, messageContains: ["success=true"]),
         ExpectedSignpost(name: "distributed_inbound_decode_arguments",
                          type: .end, messageContains: ["success=true"])]
      )
    }

    await runAllTestsAsync()
  }
}
