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
  fputs("    \(s)    // (at \(#file):\(#line))\n", stderr)
//  print(s)
}

public struct ProgressValue: CustomStringConvertible {
  public var completed: Int
  public var total: Int

  public var fractionCompleted: Double {
    Double(completed) / Double(total)
  }

  public enum Phase {
    case active
    case cancelled
    case finished

    var label: String {
      switch self {
      case .active:
        return "active"
      case .cancelled:
        return "cancelled"
      case .finished:
        return "finished"
      }
    }
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

  public var asciiProgressBar: String {
    guard completed > 0 else {
      return "[] 0%"
    }

    let doneParts = Int(fractionCompleted * 10)
    let done = String(repeating: "░", count: min(doneParts, 10))
    let remaining = String(repeating: "_", count: max(10 - doneParts, 0))
    return "[\(done)\(remaining)] \(Int(fractionCompleted * 100))%"
  }

  public var description: String {
    "\(Self.self)(completed: \(completed), total: \(total), fractionCompleted: \(fractionCompleted), phase: \(phase.label))"
  }
}

public protocol ProgressHandler: AnyObject, UnsafeConcurrentValue {
  func claim(file: String, line: UInt, function: String) -> ((ProgressValue) -> ())

  func callAsFunction(_ child: ProgressValue, from childID: ObjectIdentifier, file: String, line: UInt)
  func finalize()
}
extension ProgressHandler {
  func callAsFunction(_ child: ProgressValue, from childID: ObjectIdentifier, file: String = #file, line: UInt = #line) {
    self.callAsFunction(child, from: childID, file: file, line: line)
  }
}

/// Simple reporter, no state -- just report value directly upwards.
final class ReporterProgressHandler: ProgressHandler, UnsafeConcurrentValue, CustomStringConvertible {
  // private let lock: Lock = Lock() // FIXME: remove

  let id: _ID = .init()

  /// Total unit count *at this level* of the progress hierarchy.
  let totalUnitCount: Int

  private var _portionOfParent : Int

  var claimedAtFile: String = ""
  var claimedAtLine: UInt = 0
  var claimedByFunction: String = ""

  private var callback: ((ProgressValue) -> ())!
  private let parent: ProgressHandler?

  init(pending totalUnitCount: Int, callback: @escaping (ProgressValue) -> ()) {
    self.totalUnitCount = totalUnitCount
    _portionOfParent = totalUnitCount

    self.parent = nil
    self.callback = callback
  }

  init(pending totalUnitCount: Int, parent parentHandler: ProgressHandler) {
    self.totalUnitCount = totalUnitCount
    _portionOfParent = totalUnitCount

    self.parent = parentHandler
    self.callback = nil
    self.callback = { progressValue in
      parentHandler(progressValue, from: self.id.id)
    }
  }

  func callAsFunction(_ progress: ProgressValue, from childID: ObjectIdentifier, file: String = #file, line: UInt = #line) {
    pprint("""
           \(self) ::: \(claimedByFunction) @ (\(file):\(line))
                   REPORT:  \(progress)
           """)
    self.callback(progress)
  }

  func finalize() {
    self.callback(.init(completed: totalUnitCount, total: totalUnitCount))
  }

  // TODO, make the claim smarter actually use the value
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
    let start = "\(Self.self)(total: \(totalUnitCount) @ \(ObjectIdentifier(self))"
    if let parent = self.parent {
      return "\(start) -> (parent: \(ObjectIdentifier(parent))"
    }
    return "\(start))"
  }
}

/// Converts child task value e.g. 3/6 into parent value, like 1/2.
final class MappingProgressHandler: ProgressHandler, UnsafeConcurrentValue, CustomStringConvertible {
  // private let lock: Lock = Lock() // FIXME: remove

  let id: _ID = .init()

  /// Total unit count *at this level* of the progress hierarchy.
  let totalUnitCount: Int

  private var _portionOfParent : Int

  private var _children: [ObjectIdentifier: ProgressValue] = [:]
  private var _selfFraction: _ProgressFraction
  private var _childFraction: _ProgressFraction

  var claimedAtFile: String = ""
  var claimedAtLine: UInt = 0
  var claimedByFunction: String = ""

  private var callback: ((ProgressValue) -> ())!
  private let parent: ProgressHandler?

  init(pending totalUnitCount: Int, callback: @escaping (ProgressValue) -> ()) {
    self.totalUnitCount = totalUnitCount

    _selfFraction = _ProgressFraction()
    _childFraction = _ProgressFraction()

    // It doesn't matter what the units are here as long as the total is non-zero
    _childFraction.total = 1

    _portionOfParent = totalUnitCount

    self.parent = nil
    self.callback = callback
  }

  init(pending totalUnitCount: Int, parent parentHandler: ProgressHandler) {
    self.totalUnitCount = totalUnitCount

    _selfFraction = _ProgressFraction()
    _childFraction = _ProgressFraction()

    // It doesn't matter what the units are here as long as the total is non-zero
    _childFraction.total = 1

    _portionOfParent = totalUnitCount

    self.parent = parentHandler
    self.callback = nil
    self.callback = { progressValue in
      parentHandler(progressValue, from: self.id.id)
    }
  }

  func callAsFunction(_ child: ProgressValue, from childID: ObjectIdentifier, file: String = #file, line: UInt = #line) {
    // Map the incoming progress into our own understanding of it.

    self._children[childID] = child

    var sumCompleted = 0
    var sumTotal = 0
    for c in _children.values {
      sumCompleted += c.completed
      sumTotal += c.total
    }

    let x = ProgressValue(completed: sumCompleted, total: sumTotal)
    let mapped = ProgressValue(completed: Int(Double(totalUnitCount) * x.fractionCompleted), total: totalUnitCount)
    pprint("""
           \(self) ::: \(claimedByFunction) @ (\(file):\(line))
                   total unit count:  \(totalUnitCount)
                       \(_children.map { "\($0)" }.joined(separator: "\n            "))
                   CHILD:  \(child)
                   MAPPED: \(mapped)
           """)
    self.callback(mapped)
  }

  func finalize() {
    var sumTotal = 0
    for c in _children.values {
      sumTotal += c.total
    }
    self.callback(ProgressValue(completed: sumTotal, total: sumTotal))
  }

  private var _overallFraction : _ProgressFraction {
    return _selfFraction + _childFraction
  }

  // TODO, make the claim smarter actually use the value
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
    let start = "\(Self.self)(total: \(totalUnitCount) @ \(ObjectIdentifier(self))"
    if let parent = self.parent {
      return "\(start) -> (parent: \(ObjectIdentifier(parent))"
    }
    return "\(start))"
  }
}

final class AggregateProgressHandler: ProgressHandler, UnsafeConcurrentValue, CustomStringConvertible {
  // private let lock: Lock = Lock() // FIXME: remove

  let id: _ID = .init()

  /// Total unit count *at this level* of the progress hierarchy.
  let totalUnitCount: Int

  private var _portionOfParent : Int

  private var _children: [ObjectIdentifier: ProgressValue] = [:]
  private var _selfFraction: _ProgressFraction
  private var _childFraction: _ProgressFraction

  var claimedAtFile: String = ""
  var claimedAtLine: UInt = 0
  var claimedByFunction: String = ""

  private var callback: ((ProgressValue) -> ())!
  private let parent: ProgressHandler?

  init(pending totalUnitCount: Int, callback: @escaping (ProgressValue) -> ()) {
    self.totalUnitCount = totalUnitCount

    _selfFraction = _ProgressFraction()
    _childFraction = _ProgressFraction()

    // It doesn't matter what the units are here as long as the total is non-zero
    _childFraction.total = 1

    _portionOfParent = totalUnitCount

    self.parent = nil
    self.callback = callback
  }

  init(pending totalUnitCount: Int, parent parentHandler: ProgressHandler) {
    self.totalUnitCount = totalUnitCount

    _selfFraction = _ProgressFraction()
    _childFraction = _ProgressFraction()

    // It doesn't matter what the units are here as long as the total is non-zero
    _childFraction.total = 1

    _portionOfParent = totalUnitCount

    self.parent = parentHandler
    self.callback = nil
    self.callback = { progressValue in
      parentHandler(progressValue, from: self.id.id)
    }
  }

  func callAsFunction(_ child: ProgressValue, from childID: ObjectIdentifier, file: String = #file, line: UInt = #line) {
    // Map the incoming progress into our own understanding of it.

    self._children[childID] = child

    var sumCompleted = 0
    var sumTotal = 0
    for c in _children.values {
      sumCompleted += c.completed
      sumTotal += self.totalUnitCount
    }

    let mapped = ProgressValue(completed: sumCompleted, total: min(totalUnitCount, sumTotal))
    pprint("""
           \(self) ::: \(claimedByFunction) @ (\(file):\(line))
                   total unit count:  \(totalUnitCount)
                       \(_children.map { "\($0)" }.joined(separator: "\n            "))
                   CHILD:  \(child)
                   SUM: \(mapped)
           """)
    self.callback(mapped)
  }

  func finalize() {
    // FIXME:
  }


  private var _overallFraction : _ProgressFraction {
    return _selfFraction + _childFraction
  }

  // TODO, make the claim smarter actually use the value
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
    var msg = "\(Self.self)(total: \(totalUnitCount) @ \(ObjectIdentifier(self))"
    if let parent = self.parent {
      msg += " -> (parent: \(ObjectIdentifier(parent))"
    }
    if claimedAtLine != 0 {
      msg += ", claimedAt: \(claimedAtFile):\(claimedAtLine)"
    }
    return "\(msg))"
  }
}

/// aggregators may only be used in "leaf" operations.
///
/// ### Avoid double-claiming progress
/// Attempting to claim a task-local progress after it was claimed by an aggregator
/// or aggregator is a programmer error and will result in warnings being logged,
/// and the "second" obtained aggregator/aggregator progress being ignored.
public struct ProgressReporter: CustomStringConvertible {

  private let id: _ID = _ID()

  /// Total count *on this level* of the progress hierarchy.
  public let totalUnitCount: Int

  /// Mutating this value reports the new progress to any configured progress observers
  public private(set) var completedUnitCount: Int

  private var createdAtFile: String
  private var createdAtLine: UInt

  let progressHandler: ReporterProgressHandler

  // No public initializers: can only be instantiated via `Task.reportProgress(pending:)`.
  internal init(
    totalUnitCount: Int,
    file: String, line: UInt,
    progressHandler: ReporterProgressHandler
  ) {
    self.completedUnitCount = 0
    self.totalUnitCount = totalUnitCount
    self.createdAtFile = file
    self.createdAtLine = line
    self.progressHandler = progressHandler
  }

  /// (Convenience) Increments the completed unit count and reports
  /// the new progress to any configured progress observers.
  public mutating func increment(by units: Int = 1, file: String = #file, line: UInt = #line, function: String = #function) {
    self.completedUnitCount += units

    guard completedUnitCount <= totalUnitCount else {
      return // ignore overflow
    }

    let progress = ProgressValue(completed: completedUnitCount, total: totalUnitCount)
    progressHandler(progress, from: self.id.id)
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

  private let id: _ID = _ID()

  /// Total count *on this level* of the progress hierarchy.
  public let totalUnitCount: Int

  /// Mutating this value reports the new progress to any configured progress observers
  public private(set) var completedUnitCount: Int

  private var createdAtFile: String
  private var createdAtLine: UInt

  let progressHandler: AggregateProgressHandler

  // No public initializers: can only be instantiated via `Task.aggregateProgress(totalUnitCount:)`.
  internal init(
    totalUnitCount: Int,
    file: String, line: UInt,
    claimed progressHandler: AggregateProgressHandler
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
  ///     let progress = Task.aggregateProgress(pending: 10)
  ///     progress.of(5) { ... }
  ///     progress.of(2) { ... } // aggregate.progress(part: 2) // of 10 ???
  ///     progress.of(3) { ... }
  ///
  /// ### Incorrect examples
  ///
  ///     let progress = Task.aggregateProgress(pending: 10)
  ///     progress.of(5) { ... }
  ///     progress.of(6) { ... } // 11 > 10, wrong accounting, over-counting!
  ///
  ///     let progress = Task.aggregateProgress(pending: 10) { progress in // "double claim!"
  ///     progress.of(5) { ... }
  ///     // 5 < 10, wrong accounting, under-counting!
  ///
  ///     func x() async {
  ///       let progress = Task.aggregateProgress(pending: 1) {  in
  ///         progress.of(1) { ... }
  ///       }
  ///       let progress = Task.aggregateProgress(pending: 1)
  ///         progress.of(1) { ... }
  ///       }
  ///     }
  public func of<T>(units: Int, body: @escaping () async -> T) async -> T {
    let existingHandler = await Task.local(\.progressHandler)

    let progressHandler = MappingProgressHandler(pending: units, parent: self.progressHandler)
    return await Task.withLocal(\.progressHandler, boundTo: progressHandler) {
      defer { self.progressHandler.finalize() }
      // TODO: handle throws
      return await body()
    }
  }

  public var description: String {
    "\(Self.self)(completed: \(completedUnitCount), total: \(totalUnitCount))"
  }
}

extension TaskLocalValues {
  var progressHandler: ProgressHandlerKey { .init() }
  struct ProgressHandlerKey: TaskLocalKey {
    static var defaultValue: ProgressHandler? { nil }

    static var inherit: TaskLocalInheritance { .never }
  }
}

class _ID: Hashable {
  lazy private(set) var id = ObjectIdentifier(self)

  static func == (lhs: _ID, rhs: _ID) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    id.hash(into: &hasher)
  }
}

internal struct _ProgressFraction : Equatable, CustomDebugStringConvertible {
  var completed : Int64
  var total : Int64
  private(set) var overflowed : Bool

  init() {
    completed = 0
    total = 0
    overflowed = false
  }

  init(double: Double, overflow: Bool = false) {
    if double == 0 {
      self.completed = 0
      self.total = 1
    } else if double == 1 {
      self.completed = 1
      self.total = 1
    }

    (self.completed, self.total) = _ProgressFraction._fromDouble(double)
    self.overflowed = overflow
  }

  init(completed: Int64, total: Int64) {
    self.completed = completed
    self.total = total
    self.overflowed = false
  }

  // ----

  internal mutating func simplify() {
    if self.total == 0 {
      return
    }

    (self.completed, self.total) = _ProgressFraction._simplify(completed, total)
  }

  internal func simplified() -> _ProgressFraction {
    let simplified = _ProgressFraction._simplify(completed, total)
    return _ProgressFraction(completed: simplified.0, total: simplified.1)
  }

  static private func _math(lhs: _ProgressFraction, rhs: _ProgressFraction, whichOperator: (_ lhs : Double, _ rhs : Double) -> Double, whichOverflow : (_ lhs: Int64, _ rhs: Int64) -> (Int64, overflow: Bool)) -> _ProgressFraction {
    // Mathematically, it is nonsense to add or subtract something with a denominator of 0. However, for the purposes of implementing Progress' fractions, we just assume that a zero-denominator fraction is "weightless" and return the other value. We still need to check for the case where they are both nonsense though.
    precondition(!(lhs.total == 0 && rhs.total == 0), "Attempt to add or subtract invalid fraction")
    guard lhs.total != 0 else {
      return rhs
    }
    guard rhs.total != 0 else {
      return lhs
    }

    guard !lhs.overflowed && !rhs.overflowed else {
      // If either has overflowed already, we preserve that
      return _ProgressFraction(double: whichOperator(lhs.fractionCompleted, rhs.fractionCompleted), overflow: true)
    }

    if let lcm = _leastCommonMultiple(lhs.total, rhs.total) {
      let result = whichOverflow(lhs.completed * (lcm / lhs.total), rhs.completed * (lcm / rhs.total))
      if result.overflow {
        return _ProgressFraction(double: whichOperator(lhs.fractionCompleted, rhs.fractionCompleted), overflow: true)
      } else {
        return _ProgressFraction(completed: result.0, total: lcm)
      }
    } else {
      // Overflow - simplify and then try again
      let lhsSimplified = lhs.simplified()
      let rhsSimplified = rhs.simplified()

      if let lcm = _leastCommonMultiple(lhsSimplified.total, rhsSimplified.total) {
        let result = whichOverflow(lhsSimplified.completed * (lcm / lhsSimplified.total), rhsSimplified.completed * (lcm / rhsSimplified.total))
        if result.overflow {
          // Use original lhs/rhs here
          return _ProgressFraction(double: whichOperator(lhs.fractionCompleted, rhs.fractionCompleted), overflow: true)
        } else {
          return _ProgressFraction(completed: result.0, total: lcm)
        }
      } else {
        // Still overflow
        return _ProgressFraction(double: whichOperator(lhs.fractionCompleted, rhs.fractionCompleted), overflow: true)
      }
    }
  }

  static internal func +(lhs: _ProgressFraction, rhs: _ProgressFraction) -> _ProgressFraction {
    return _math(lhs: lhs, rhs: rhs, whichOperator: +, whichOverflow: { $0.addingReportingOverflow($1) })
  }

  static internal func -(lhs: _ProgressFraction, rhs: _ProgressFraction) -> _ProgressFraction {
    return _math(lhs: lhs, rhs: rhs, whichOperator: -, whichOverflow: { $0.subtractingReportingOverflow($1) })
  }

  static internal func *(lhs: _ProgressFraction, rhs: _ProgressFraction) -> _ProgressFraction {
    guard !lhs.overflowed && !rhs.overflowed else {
      // If either has overflowed already, we preserve that
      return _ProgressFraction(double: rhs.fractionCompleted * rhs.fractionCompleted, overflow: true)
    }

    let newCompleted = lhs.completed.multipliedReportingOverflow(by: rhs.completed)
    let newTotal = lhs.total.multipliedReportingOverflow(by: rhs.total)

    if newCompleted.overflow || newTotal.overflow {
      // Try simplifying, then do it again
      let lhsSimplified = lhs.simplified()
      let rhsSimplified = rhs.simplified()

      let newCompletedSimplified = lhsSimplified.completed.multipliedReportingOverflow(by: rhsSimplified.completed)
      let newTotalSimplified = lhsSimplified.total.multipliedReportingOverflow(by: rhsSimplified.total)

      if newCompletedSimplified.overflow || newTotalSimplified.overflow {
        // Still overflow
        return _ProgressFraction(double: lhs.fractionCompleted * rhs.fractionCompleted, overflow: true)
      } else {
        return _ProgressFraction(completed: newCompletedSimplified.0, total: newTotalSimplified.0)
      }
    } else {
      return _ProgressFraction(completed: newCompleted.0, total: newTotal.0)
    }
  }

  static internal func /(lhs: _ProgressFraction, rhs: Int64) -> _ProgressFraction {
    guard !lhs.overflowed else {
      // If lhs has overflowed, we preserve that
      return _ProgressFraction(double: lhs.fractionCompleted / Double(rhs), overflow: true)
    }

    let newTotal = lhs.total.multipliedReportingOverflow(by: rhs)

    if newTotal.overflow {
      let simplified = lhs.simplified()

      let newTotalSimplified = simplified.total.multipliedReportingOverflow(by: rhs)

      if newTotalSimplified.overflow {
        // Still overflow
        return _ProgressFraction(double: lhs.fractionCompleted / Double(rhs), overflow: true)
      } else {
        return _ProgressFraction(completed: lhs.completed, total: newTotalSimplified.0)
      }
    } else {
      return _ProgressFraction(completed: lhs.completed, total: newTotal.0)
    }
  }

  static internal func ==(lhs: _ProgressFraction, rhs: _ProgressFraction) -> Bool {
    if lhs.isNaN || rhs.isNaN {
      // NaN fractions are never equal
      return false
    } else if lhs.completed == rhs.completed && lhs.total == rhs.total {
      return true
    } else if lhs.total == rhs.total {
      // Direct comparison of numerator
      return lhs.completed == rhs.completed
    } else if lhs.completed == 0 && rhs.completed == 0 {
      return true
    } else if lhs.completed == lhs.total && rhs.completed == rhs.total {
      // Both finished (1)
      return true
    } else if (lhs.completed == 0 && rhs.completed != 0) || (lhs.completed != 0 && rhs.completed == 0) {
      // One 0, one not 0
      return false
    } else {
      // Cross-multiply
      let left = lhs.completed.multipliedReportingOverflow(by: rhs.total)
      let right = lhs.total.multipliedReportingOverflow(by: rhs.completed)

      if !left.overflow && !right.overflow {
        if left.0 == right.0 {
          return true
        }
      } else {
        // Try simplifying then cross multiply again
        let lhsSimplified = lhs.simplified()
        let rhsSimplified = rhs.simplified()

        let leftSimplified = lhsSimplified.completed.multipliedReportingOverflow(by: rhsSimplified.total)
        let rightSimplified = lhsSimplified.total.multipliedReportingOverflow(by: rhsSimplified.completed)

        if !leftSimplified.overflow && !rightSimplified.overflow {
          if leftSimplified.0 == rightSimplified.0 {
            return true
          }
        } else {
          // Ok... fallback to doubles. This doesn't use an epsilon
          return lhs.fractionCompleted == rhs.fractionCompleted
        }
      }
    }

    return false
  }

  // ----

  internal var isIndeterminate : Bool {
    return completed < 0 || total < 0 || (completed == 0 && total == 0)
  }

  internal var isFinished : Bool {
    return ((completed >= total) && completed > 0 && total > 0) || (completed > 0 && total == 0)
  }

  internal var fractionCompleted : Double {
    if isIndeterminate {
      // Return something predictable
      return 0.0
    } else if total == 0 {
      // When there is nothing to do, you're always done
      return 1.0
    } else {
      return Double(completed) / Double(total)
    }
  }

  internal var isNaN : Bool {
    return total == 0
  }

  internal var debugDescription : String {
    return "\(completed) / \(total) (\(fractionCompleted))"
  }

  // ----

  private static func _fromDouble(_ d : Double) -> (Int64, Int64) {
    // This simplistic algorithm could someday be replaced with something better.
    // Basically - how many 1/Nths is this double?
    // And we choose to use 131072 for N
    let denominator : Int64 = 131072
    let numerator = Int64(d / (1.0 / Double(denominator)))
    return (numerator, denominator)
  }

  private static func _greatestCommonDivisor(_ inA : Int64, _ inB : Int64) -> Int64 {
    // This is Euclid's algorithm. There are faster ones, like Knuth, but this is the simplest one for now.
    var a = inA
    var b = inB
    repeat {
      let tmp = b
      b = a % b
      a = tmp
    } while (b != 0)
    return a
  }

  private static func _leastCommonMultiple(_ a : Int64, _ b : Int64) -> Int64? {
    // This division always results in an integer value because gcd(a,b) is a divisor of a.
    // lcm(a,b) == (|a|/gcd(a,b))*b == (|b|/gcd(a,b))*a
    let result = (a / _greatestCommonDivisor(a, b)).multipliedReportingOverflow(by: b)
    if result.overflow {
      return nil
    } else {
      return result.0
    }
  }

  private static func _simplify(_ n : Int64, _ d : Int64) -> (Int64, Int64) {
    let gcd = _greatestCommonDivisor(n, d)
    return (n / gcd, d / gcd)
  }

}

public struct TaskLocalProgress {

  /// Initial "outer" entry point, setting up progress monitoring for the entire contained call chain.
  public static func withProgressObserver<T>(
    totalUnitCount: Int = 1,
    _ onProgressUpdate: @concurrent @escaping (ProgressValue) -> (),
    file: String = #file, line: UInt = #line, function: String = #function,
    operation: () async -> T
    ) async -> T {

    // FIXME: thread safety here, express it otherwise
    var sum = ProgressValue(completed: 0, total: totalUnitCount)
    let progressHandler = AggregateProgressHandler(pending: totalUnitCount) { addChildProgress in // FIXME: edge handler
      pprint("xxxxx addChildProgress == \(addChildProgress)")
      sum.completed = Int(Double(totalUnitCount) * addChildProgress.fractionCompleted)
      onProgressUpdate(sum)
    }

    pprint("\(#function) made progressHandler \(progressHandler)")

    return await Task.withLocal(\.progressHandler, boundTo: progressHandler) {
      await operation()
    }
  }
}

extension TaskLocalProgress {

  public static func aggregate(
    pending aggregateTotalUnitCount: Int,
    file: String = #file, line: UInt = #line, function: String = #function
  ) async -> ProgressAggregator {
    guard let progressHandler = await Task.local(\.progressHandler) else {
      let noopHandler = AggregateProgressHandler(pending: aggregateTotalUnitCount) { _ in /* noop */ }
      var aggregator = ProgressAggregator(totalUnitCount: 1, file: file, line: line, claimed: noopHandler)
      return aggregator
    }

    let callback = progressHandler.claim(file: file, line: line, function: function)

    // As we're reporting things in this "leaf" task no other operation
    // may report things.
    let handler = AggregateProgressHandler(pending: aggregateTotalUnitCount, parent: progressHandler)
    let aggregator = ProgressAggregator(totalUnitCount: aggregateTotalUnitCount, file: file, line: line, claimed: handler)
    // TODO: catch when we throw, the progress must mark it has failed
    return aggregator
  }

  /// Must only be called in a "leaf" operation.
  public static func report(
    pending leafTotalUnitCount: Int,
    file: String = #file, line: UInt = #line, function: String = #function
  ) async -> ProgressReporter {
    guard let progressHandler = await Task.local(\.progressHandler) else {
      let noopHandler = ReporterProgressHandler(pending: 1) { _ in /* noop */ }
      var reporter = ProgressReporter(totalUnitCount: 1, file: file, line: line, progressHandler: noopHandler)
      return reporter
    }

    let callback = progressHandler.claim(file: file, line: line, function: function)

    let handler = ReporterProgressHandler(pending: leafTotalUnitCount, parent: progressHandler)
    _ = handler.claim(file: file, line: line, function: #function)
    var reporter = ProgressReporter(totalUnitCount: leafTotalUnitCount, file: file, line: line, progressHandler: handler)
    // TODO: defer { when we return the progress must jump to 100% }
    // TODO: catch when we throw, the progress must mark it has failed
    return reporter
  }
}


// ==== ------------------------------------------------------------------------

func test() async {
  await TaskLocalProgress.withProgressObserver(totalUnitCount: 10) { progress in
    print("Progress: \(progress.asciiProgressBar)      // details: \(progress)")
  } operation: {
    try! await makeDinner()
  }
}

func makeDinner() async throws -> Meal {
  let progress = await TaskLocalProgress.aggregate(pending: 10)
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

func chopVegetables() async -> String {
  var report = await TaskLocalProgress.report(pending: 2)
  pprint("INCREMENT PROGRESS to 1/2 in \(#function)")
  report.increment() // 1/2 50%  here; 3/6 = 50% in parent; 3/10 = 30% in top
  pprint("INCREMENT PROGRESS to 2/2 in \(#function)")
  report.increment() // 2/2 100% here; 6/6 = 100% in parent; 3/10 = 60% in top
  pprint("PROGRESS DONE in \(#function)")
  return "veggies"
}

func marinateMeat() async -> String {
  "meat"
}

func preheatOven(temperature: Int) async -> Oven {
  var report = await TaskLocalProgress.report(pending: 8)
  for _ in 1...8 {
    report.increment()
  }
  return .init()
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

func demo2() async {
  await TaskLocalProgress.withProgressObserver(totalUnitCount: 10) { progressValue in
    print("Progress: \(progressValue.asciiProgressBar)      // details: \(progressValue)")
    pprint(">>>> Progress: \(progressValue.asciiProgressBar)      // details: \(progressValue) <<<")
  } operation: {
    await demo2_observedWork()
  }
}

func demo2_observedWork() async {
  let progress = await TaskLocalProgress.aggregate(pending: 10)

  print("Child 1")
  await progress.of(units: 2) {
    var report = await TaskLocalProgress.report(pending: 6)
    for i in 1...6 {
      pprint("INCREMENT: \(i)/\(6)")
      print("INCREMENT: \(i)/\(6)")
      report.increment()
    } // 6/6 -> 2/2 -> 2/10
  } // end of child 1

  print("Child 2")
  await progress.of(units: 8) {
    var report = await TaskLocalProgress.report(pending: 20)
    for i in 1...20 {
      pprint("INCREMENT: \(i)/\(20)")
      print("INCREMENT: \(i)/\(20)")
      report.increment()
    } // 6/6 -> 2/2 -> 2/10
  } // end of child 2
}

// ==== ------------------------------------------------------------------------

@main struct Main {
  static func main() async {
    // CHECK: Progress: x
//    _ = try! await test()
    _ = try! await demo2()

  }
}

