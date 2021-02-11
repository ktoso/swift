// RUN: %target-run-simple-swift(-Xfrontend -enable-experimental-concurrency -parse-as-library) | %FileCheck %s --dump-input always
// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: foundation

// import Foundation // FIXME: remove, only for the lock

struct ProgressBox {
  // private let lock: Lock = Lock() // FIXME: remove

  var claimedAtFile: String = ""
  var claimedAtLine: UInt = 0

  private let callback: (ProgressValue) -> ()

  init(callback: (ProgressValue) -> ()) {
    self.callback = callback
  }

  func claim(file: String, line: UInt) -> ((ProgressValue) -> ()){
//    lock.lock()
//    defer { lock.unlock() }

    guard claimedAtLine > 0 else {
      print("OK: Progress box: claimed at \(file):\(line)")
      return self.callback
    }

    fatalError("""
               Failed to claim progress reporter at [\(file):\(line)], was \
               previously claimed at \(self.claimedAtFile):\(self.claimedAtLine)
               """)
  }
}

/// Reports the current progress of a task.
public struct ProgressReporter {
  public let totalUnitCount: Int

  let progressHandler: (ProgressValue) -> Void

  /// Mutating this value reports the new progress to any configured
  /// progress observers
  public var completedUnitCount: Int

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

  // No public initializers: can only be instantiated via
  // `Task.progressReporter(totalUnitCount:)`.
  internal init(
    totalUnitCount: Int,
    progressHandler: @escaping (ProgressValue) -> Void) {
    self.totalUnitCount = totalUnitCount
    self.progressHandler = progressHandler
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
  var progress: ProgressKey { .init() }
  enum ProgressKey: TaskLocalKey {
    static var defaultValue: ProgressValue? { nil }

    static var inherit: TaskLocalInheritance { .never }
  }
}

extension Task {

  static func withProgressObserver<T>(
    _ onProgressUpdate: @concurrent (ProgressValue) -> (),
    operation: () async throws -> T
  ) async rethrows -> T {
    let box = ProgressBox()
    return try await Task.withLocal(\.progress, boundTo: box) {
      try await operation
    }
  }

  static func withProgress(pending: Int) async {
    if let parentBox = await Task.local(\.progress) {

    }
  }

  static func reportingProgress(
    pending: Int,
    file: String = #file, line: UInt = #line
  ) async -> ProgressReporter {
    if let box = await Task.local(\.progress) {
      let callback = box.claim(file: file, line: line)

      // unbind the progress!
      return await Task.withLocal(\.progress, boundTo: nil) {
        // As we're reporting things in this "leaf" task no other operation
        // may report things.
        return ProgressReporter(totalUnitCount: pending) {
          fatalError()
        }
      }
    } else {
      return ProgressReporter(totalUnitCount: 1) {
        /* noop */
      }
    }
  }
}

// ==== ------------------------------------------------------------------------

func test() async {
  func makeDinner() async throws -> Meal {
    await Task.reportingProgress(pending: 5) { progress in
      async let veggies = await progress.withPendingProgress(1) {
        await chopVegetables()
      }
      async let meat = marinateMeat()

      async let oven = await progress.withPendingProgress(3) {
        await preheatOven(temperature: 350)
      }

      let dish = Dish(ingredients: await [veggies, meat])
      let dinner = await progress.withPendingProgress(1) {
        await oven.cook(dish)
      }

      return dinner
    }
  }

  func chopVegetables() async -> [String] {
    return []
  }

  func marinateMeat() async -> String {
    ""
  }

  func preheatOven(temperature: Int) -> Oven {
    .init()
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
        print("    progress: \(progress)")
      } operation: {
        body()
      }
    }
  }
}

// ==== ------------------------------------------------------------------------

@main struct Main {
  static func main() async {
    await button()
    await test()
  }
}

