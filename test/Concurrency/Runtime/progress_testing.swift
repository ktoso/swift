// RUN: %target-run-simple-swift(-Xfrontend -enable-experimental-concurrency  %import-libdispatch -parse-as-library) | %FileCheck %s --dump-input=always

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: libdispatch

import Dispatch

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

func pprint(_ s: String) {
  fputs("    \(s)    (at \(#file):\(#line))\n", stderr)
//  print(s)
}

class ProgressHandler: UnsafeConcurrentValue, CustomStringConvertible {
  // private let lock: Lock = Lock() // FIXME: remove

  var claimedAtFile: String = ""
  var claimedAtLine: UInt = 0
  var claimedByFunction: String = ""

  private let callback: (ProgressValue) -> ()

  init(callback: @escaping (ProgressValue) -> ()) {
    self.callback = callback
  }

  func callAsFunction(_ value: ProgressValue) {
    self.callback(value)
  }

  func claim(file: String, line: UInt, function: String) -> ((ProgressValue) -> ()){
//    lock.lock()
//    defer { lock.unlock() }

    guard claimedAtLine == 0 else {
      pprint("CLAIM FAILED (\(self)), by \(function) on \(file):\(line); already claimed by \(claimedAtFile):\(claimedAtLine)")
//      fatalError("""
//                 Failed to claim progress aggregator at [\(file):\(line)], was \
//                 previously claimed at \(self.claimedAtFile):\(self.claimedAtLine)
//                 """)
      return { _ in () }
    }
    pprint("CLAIM OK (\(self)), by \(function) on \(file):\(line)")

    self.claimedAtFile = file
    self.claimedAtLine = line
    self.claimedByFunction = function

    return callback
  }

  public var description: String {
    "\(Self.self)(\(ObjectIdentifier(self)))"
  }
}

/// aggregators may only be used in "leaf" operations.
///
/// ### Avoid double-claiming progress
/// Attempting to claim a task-local progress after it was claimed by an aggregator
/// or aggregator is a programmer error and will result in warnings being logged,
/// and the "second" obtained aggregator/aggregator progress being ignored.
public struct ProgressReporter: CustomStringConvertible {

  /// Total count *on this level* of the progress hierarchy.
  public let totalUnitCount: Int

  /// Mutating this value reports the new progress to any configured progress observers
  public private(set) var completedUnitCount: Int

  private var createdAtFile: String
  private var createdAtLine: UInt

  let progressHandler: (ProgressValue) -> Void

  // No public initializers: can only be instantiated via
  // `Task.reportProgress(pending:)`.
  internal init(
    totalUnitCount: Int,
    file: String, line: UInt,
    progressHandler: @escaping (ProgressValue) -> Void
  ) {
    self.completedUnitCount = 0
    self.totalUnitCount = totalUnitCount
    self.createdAtFile = file
    self.createdAtLine = line
    self.progressHandler = progressHandler
  }

  /// (Convenience) Increments the completed unit count and reports
  /// the new progress to any configured progress observers.
  public mutating func increment(by units: Int = 1) {
    self.completedUnitCount += units

    let progress = ProgressValue(
      completed: self.completedUnitCount,
      total: self.totalUnitCount
    )

    progressHandler(progress)
  }

  public var description: String {
    "\(Self.self)(completed: \(completedUnitCount), total: \(totalUnitCount), handler: \(progressHandler))"
  }
}

/// Aggregators must be used when an operation consists of multiple operations.
///
/// ### Avoid double-claiming progress
/// Attempting to claim a task-local progress after it was claimed by an aggregator
/// or aggregator is a programmer error and will result in warnings being logged,
/// and the "second" obtained aggregator/aggregator progress being ignored.
public struct ProgressAggregator: CustomStringConvertible {

  /// Total count *on this level* of the progress hierarchy.
  public let totalUnitCount: Int

  /// Mutating this value reports the new progress to any configured progress observers
  public private(set) var completedUnitCount: Int

  private var createdAtFile: String
  private var createdAtLine: UInt

  let progressHandler: ProgressHandler

  // No public initializers: can only be instantiated via
  // `Task.aggregateProgress(totalUnitCount:)`.
  internal init(
    totalUnitCount: Int,
    file: String, line: UInt,
    claimed progressHandler: ProgressHandler
  ) {
    self.completedUnitCount = 0
    self.totalUnitCount = totalUnitCount
    self.createdAtFile = file
    self.createdAtLine = line
    self.progressHandler = progressHandler
  }

  /// The sum of all `N` unit counts passed to all `of(units:body:)`
  /// - Returns:calls within a single `aggregateProgress(pending:)` MUST equal
  /// the `totalUnitCount` that was passed to `aggregateProgress` as the `pending`
  /// value.
  ///
  /// ### Correct examples
  ///
  ///     Task.aggregateProgress(pending: 10) { progress in
  ///       progress.of(5) { ... }
  ///       progress.of(2) { ... }
  ///       progress.of(3) { ... }
  ///     }
  ///
  /// ### Incorrect examples
  ///
  ///     Task.aggregateProgress(pending: 10) { progress in
  ///       progress.of(5) { ... }
  ///       progress.of(6) { ... } // 11 > 10, wrong accounting, over-counting!
  ///     }
  ///
  ///     Task.aggregateProgress(pending: 10) { progress in
  ///       progress.of(5) { ... }
  ///       // 5 < 10, wrong accounting, under-counting!
  ///     }
  ///
  ///     func x() async {
  ///       Task.aggregateProgress(pending: 1) { progress in
  ///         progress.of(1) { ... }
  ///       }
  ///       Task.aggregateProgress(pending: 1) { progress in // wrong! progress already claimed as aggregate in previous line
  ///         progress.of(1) { ... }
  ///       }
  ///     }
  public func of<T>(units: Int, body: @escaping () async -> T) async -> T {
    let existingHandler = await Task.local(\.progressHandler)
    pprint("    \(#function) existing progress \(existingHandler)")
    assert(existingHandler == nil, "no task local progress should exist here")

    let progressHandler = ProgressHandler { value in
      pprint("        report progress: \(value), handler (\(self)), delegating up to \(self.progressHandler)...")
      self.progressHandler(value)
    }
    return await Task.withLocal(\.progressHandler, boundTo: progressHandler) {
      pprint("    \(#function) run body, bound handler: \(progressHandler)")
      defer {
        // even if the body never incremented progress at all, we guarantee that
        // as we exit here the `units` amount of progress is completed!
        let completed = ProgressValue(completed: units, total: units)
        progressHandler(completed)
      }
      // TODO: handle throws
      return await body()
    }
  }

  public var description: String {
    "\(Self.self)(completed: \(completedUnitCount), total: \(totalUnitCount))"
  }
}

public struct ProgressValue {
  public var total: Int
  public var completed: Int

  public var fractionCompleted: Double {
    Double(completed) / Double(total)
  }

  public enum Phase {
    case active
    case cancelled
    case finished
  }
  public var phase: Phase

  init(total: Int) {
    self.completed = 0
    self.total = total
    self.phase = .active
  }

  init(completed: Int, total: Int) {
    self.completed = completed
    self.total = total
    self.phase = .active
  }
}

extension TaskLocalValues {
  var progressHandler: ProgressHandlerKey { .init() }
  struct ProgressHandlerKey: TaskLocalKey {
    static var defaultValue: ProgressHandler? { nil }

    static var inherit: TaskLocalInheritance { .never }
  }
}

extension Task {

  /// Initial "outer" entry point, setting up progress monitoring for the entire contained call chain.
  static func withProgressObserver<T>(
    _ onProgressUpdate: @concurrent @escaping (ProgressValue) -> (),
    operation: () async -> T
  ) async -> T {
    let progressHandler = ProgressHandler { value in
      onProgressUpdate(value)
    }

    pprint("\(#function) made progressHandler \(progressHandler)")

    var progressValue = ProgressValue(total: 1)
    return await Task.withLocal(\.progressHandler, boundTo: progressHandler) {
      await operation()
    }
  }

  static func reportProgress<T>(
    pending: Int,
    file: String = #file, line: UInt = #line, function: String = #function,
    body: (inout ProgressReporter) async -> T
  ) async -> T {
    pprint("\(#function)")
    guard let progressHandler = await Task.local(\.progressHandler) else {
      pprint("\(#function): progressHandler = no progressHandler, do noop")
      var reporter = ProgressReporter(totalUnitCount: 1, file: file, line: line) { _ in
        pprint("noop (\(#function))")
        /* noop */
      }
      return await body(&reporter)
    }

    pprint("\(#function): CLAIM progressHandler = \(progressHandler)")
    let callback = progressHandler.claim(file: file, line: line, function: function)

    // unbind the progress
    return await Task.withLocal(\.progressHandler, boundTo: nil) {
      var reporter = ProgressReporter(totalUnitCount: pending, file: file, line: line) { value in
        pprint("[\(#file):\(#line)] reporter: \(value) (progressHandler: \(progressHandler))")
        // TODO: math here
        callback(value)
      }
      // TODO: defer { when we return the progress must jump to 100% }
      // TODO: catch when we throw, the progress must mark it has failed
      return await body(&reporter)
    }
  }

  static func aggregateProgress<T>(
    pending: Int,
    file: String = #file, line: UInt = #line, function: String = #function,
    body: (inout ProgressAggregator) async -> T
  ) async -> T {
    pprint("\(#function)")
    guard let progressHandler = await Task.local(\.progressHandler) else {
      pprint("\(#function): progressHandler = no progressHandler, do noop")

      let noopHandler = ProgressHandler { _ in
        pprint("noop (\(#function))")
        /* noop */
      }
      var aggregator = ProgressAggregator(totalUnitCount: 1, file: file, line: line, claimed: noopHandler)
      return await body(&aggregator)
    }

    let callback = progressHandler.claim(file: file, line: line, function: function)

    // unbind the progress!
    return await Task.withLocal(\.progressHandler, boundTo: nil) {
      // As we're reporting things in this "leaf" task no other operation
      // may report things.
      let handler = ProgressHandler { value in
        pprint("[\(#file):\(#line)] aggregator: \(value) (progressHandler: \(progressHandler))")
        // TODO: math here
        callback(value)
      }
      var aggregator = ProgressAggregator(totalUnitCount: pending, file: file, line: line, claimed: handler)
      // TODO: defer { when we return the progress must jump to 100% }
      // TODO: catch when we throw, the progress must mark it has failed
      return await body(&aggregator)
    }
  }
}

// ==== ------------------------------------------------------------------------

func test() async {
  await Task.withProgressObserver { progress in
    print("Progress: \(progress)")
  } operation: {
    try! await makeDinner()
  }
}

func makeDinner() async throws -> Meal {
  await Task.aggregateProgress(pending: 10) { progress in
    print(">> before veggies")
    /*async*/ let veggies = await progress.of(units: 2) {
      await chopVegetables()
    }
    print(">> before meat")
    /*async*/ let meat = await marinateMeat()

    print(">> before oven")
    /*async*/ let oven = await progress.of(units: 6) {
      await preheatOven(temperature: 350)
    }

    print(">> before dinner")
    let dish = Dish(ingredients: await[veggies, meat])
    let dinner = await progress.of(units: 2) {
      await oven.cook(dish)
    }

    print(">> done")
    return dinner
  }
}

func chopVegetables() async -> String {
  return "veggies"
}

func marinateMeat() async -> String {
  "meat"
}

func preheatOven(temperature: Int) async -> Oven {
  await Task.reportProgress(pending: 2) { progress in
    progress.increment() // 1/2 50%  here; 3/6 = 50% in parent; 3/10 = 30% in top
    progress.increment() // 2/2 100% here; 6/6 = 100% in parent; 3/10 = 60% in top
    return .init()
  }
}

struct Dish {
  init(ingredients: [String]) {}
}

struct Meal {}

struct Oven {
  func cook(_ dish: Dish) async -> Meal {
    return .init()
  }
}

// ==== ------------------------------------------------------------------------

func button() async {
  struct Button {
    let name: String
    init(_ name: String) {
    self.name = name
    }

    func callAsFunction(body: () async -> Void) async {
      await Task.withProgressObserver { progress in
        pprint("    progress: \(progress)")
      } operation: {
        await body()
      }
    }
  }
}

// ==== ------------------------------------------------------------------------

@main struct Main {
  static func main() async {
    // CHECK: Progress: x
    _ = try! await test()

    await button()
  }
}

