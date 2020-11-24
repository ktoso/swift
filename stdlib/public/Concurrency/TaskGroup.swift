////===----------------------------------------------------------------------===//
////
//// This source file is part of the Swift.org open source project
////
//// Copyright (c) 2020 Apple Inc. and the Swift project authors
//// Licensed under Apache License v2.0 with Runtime Library Exception
////
//// See https://swift.org/LICENSE.txt for license information
//// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
////
////===----------------------------------------------------------------------===//

import Swift
import Dispatch
@_implementationOnly import _SwiftConcurrencyShims

// ==== Task Group -------------------------------------------------------------

extension Task {

  /// Starts a new task group which provides a scope in which a dynamic number of
  /// tasks may be spawned.
  ///
  /// Tasks added to the group by `group.add()` will automatically be awaited on
  /// when the scope exits. If the group exits by throwing, all added tasks will
  /// be cancelled and their results discarded.
  ///
  /// ### Implicit awaiting
  /// When results of tasks added to the group need to be collected, one can
  /// gather their results using the following pattern:
  ///
  ///     while let result = await group.next() {
  ///       // some accumulation logic (e.g. sum += result)
  ///     }
  ///
  /// ### Thrown errors
  /// When tasks are added to the group using the `group.add` function, they may
  /// immediately begin executing. Even if their results are not collected explicitly
  /// and such task throws, and was not yet cancelled, it may result in the `withGroup`
  /// throwing.
  ///
  /// ### Cancellation
  /// If an error is thrown out of the task group, all of its remaining tasks
  /// will be cancelled and the `withGroup` call will rethrow that error.
  ///
  /// Individual tasks throwing results in their corresponding `try group.next()`
  /// call throwing, giving a chance to handle individual errors or letting the
  /// error be rethrown by the group.
  ///
  /// Postcondition:
  /// Once `withGroup` returns it is guaranteed that the `group` is *empty*.
  ///
  /// This is achieved in the following way:
  /// - if the body returns normally:
  ///   - the group will await any not yet complete tasks,
  ///     - if any of those tasks throws, the remaining tasks will be cancelled,
  ///   - once the `withGroup` returns the group is guaranteed to be empty.
  /// - if the body throws:
  ///   - all tasks remaining in the group will be automatically cancelled.
  // TODO: Do we have to add a different group type to accommodate throwing
  //       tasks without forcing users to use Result?  I can't think of how that
  //       could be propagated out of the callback body reasonably, unless we
  //       commit to doing multi-statement closure typechecking.
  public static func withGroup<TaskResult, BodyResult>(
    resultType: TaskResult.Type,
    returning returnType: BodyResult.Type = BodyResult.self,
    cancelOutstandingTasksOnReturn: Bool = false,
    body: @escaping ((inout Task.Group<TaskResult>) async throws -> BodyResult)
  ) async throws -> BodyResult {
    let drainPendingTasksOnSuccessfulReturn = !cancelOutstandingTasksOnReturn
    let parent = Builtin.getCurrentAsyncTask()

    // Set up the job flags for a new task.
    var groupFlags = JobFlags()
    groupFlags.kind = .task
    groupFlags.priority = getJobFlags(parent).priority
    groupFlags.isFuture = true
    groupFlags.isChildTask = true

    // 1. Prepare the Group task
    var group = Task.Group<TaskResult>(parentTask: parent)

    let (groupTask, _) =
      Builtin.createAsyncTaskFuture(groupFlags.bits, parent) { () async throws -> BodyResult in
        await try body(&group)
      }
    let groupHandle = Handle<BodyResult>(task: groupTask)

    // 2.0) Run the task!
    DispatchQueue.global(priority: .default).async { // FIXME: use executors when they land
      groupHandle.run()
    }

    // 2.1) ensure that if we fail and exit by throwing we will cancel all tasks,
    // if we succeed, there is nothing to cancel anymore so this is noop
    defer { group.cancelAll() }

    // 2.2) Await the group completing it's run ("until the withGroup returns")
    let result = await try groupHandle.get() // if we throw, so be it -- group tasks will be cancelled

// TODO: do drain before exiting
//    if drainPendingTasksOnSuccessfulReturn {
//      // drain all outstanding tasks
//      while await try group.next() != nil {
//        continue // awaiting all remaining tasks
//      }
//    }

    return result
  }

  /// A task group serves as storage for dynamically started tasks.
  ///
  /// Its intended use is with the `Task.withGroup` function.
  /* @unmoveable */
  public struct Group<TaskResult> {
    private let parentTask: Builtin.NativeObject

    // TODO: remove
    var allTasks: [Int: Handle<TaskResult>] = [:]

    let lock: _Mutex
    final class Storage {

      var tasksToPull: Int = 0 // TODO: instead implement as a status Int?

      var completedTaskQueue: [Int] = []

      /// If present, the handle on which the `next()` call is awaiting,
      /// it should be resumed by *any* of the in-flight tasks completing.
      var wakeUpNext: Handle<Void>? = nil

      // TODO: ATOMIC && combined with Status
      let closed: Bool = false

      init() {
      }

      func pollCompletedTask() -> Int? {
        if self.completedTaskQueue.isEmpty {
          return nil
        } else {
          return self.completedTaskQueue.removeFirst()
        }
      }

    }
    let storage: Storage

//    private var nextHandle: Task.Handle<TaskResult>? = nil

    /// No public initializers
    init(parentTask: Builtin.NativeObject) {
      self.parentTask = parentTask

      self.lock = _Mutex()
      self.storage = .init()
    }

    var isClosed: Bool {
      self.lock.synchronized {
        self.storage.closed
      }
    }

    var nextTaskID: Int = 0

    // Swift will statically prevent this type from being copied or moved.
    // For now, that implies that it cannot be used with generics.

    /// Add a child task to the group.
    ///
    /// ### Error handling
    /// Operations are allowed to `throw`, in which case the `await try next()`
    /// invocation corresponding to the failed task will re-throw the given task.
    ///
    /// The `add` function will never (re-)throw errors from the `operation`.
    /// Instead, the corresponding `next()` call will throw the error when necessary.
    ///
    /// - Parameters:
    ///   - overridingPriority: override priority of the operation task
    ///   - operation: operation to execute and add to the group
    @discardableResult
    public mutating func add(
      overridingPriority: Priority? = nil,
      operation: @escaping () async throws -> TaskResult
    ) async -> Task.Handle<TaskResult> {
      var flags = JobFlags()
      flags.kind = .task
      flags.priority = overridingPriority ?? getJobFlags(parentTask).priority
      flags.isFuture = true
      flags.isChildTask = true

      let taskID = self.nextTaskID
      self.nextTaskID += 1

      let lock = self.lock
      let storage = self.storage

      let storageOperation = { () async throws -> TaskResult in
        defer {
          var oldStatus: Int = lock.synchronized {
            storage.completedTaskQueue.append(taskID)

            // TODO: cas +1 the status, if we activated we perform the wakeup
            let oldStatus = storage.tasksToPull
            storage.tasksToPull += 1
            return oldStatus
          }

          if oldStatus == 0 {
            guard let wakeUpNext = storage.wakeUpNext else {
              fatalError("No wakeUpNextContinuation available! Task ID completed: \(taskID)")
            }
            cc.resume(returning: ())
          } // no need to wake-up
        }

        let result = await try operation()
        print("<<< task [\(taskID)] completed: \(result)")
        return result
      }
  
//      self.lock.synchronized {
//        if storage.wakeUpNext == nil {
//          // TODO: TERRIBLE HACK TO INVENT A PROMISE
//          storage.wakeUpNext = Task.runDetached {
//            await Task.withUnsafeContinuation { cc in
//              // PURPOSEFULLY DO NOT COMPLETE; TERRIBLE HACK, to abuse this
//              // handle as a promise, that we will unlock when a child task
//              // completes and by doing so, we'll awaken the next() caller.
//            }
//          }
//        }
//      }

      let (childTask, _) =
        Builtin.createAsyncTaskFuture(flags.bits, parentTask, storageOperation)
      let handle = Handle<TaskResult>(task: childTask)

      // we must store the handle before starting its task
      self.allTasks[taskID] = handle

      // FIXME: use executors or something else to launch the task
      DispatchQueue.global(priority: .default).async {
        print(">>> run")
        handle.run()
      }

      return handle
    }

    /// Wait for a child task to complete and return the result it returned,
    /// or else return.
    ///
    /// Order of completions is *not* guaranteed to be same as submission order,
    /// rather the order of `next()` calls completing is by completion order of
    /// the tasks. This differentiates task groups from streams (
    public mutating func next() async throws -> TaskResult? {
      let maybeWakeUpNext = self.lock.synchronized { self.storage.wakeUpNext }

      guard let wakeUpHandle = maybeWakeUpNext else {
        // no tasks in flight, so we return immediately
        return nil
      }

      // wait until _any_ task completes
      await try wakeUpHandle.get()

      // TODO: optimize by yielding the result right there right away?

      guard let completedTaskID: Int = self.lock.synchronized({ storage.pollCompletedTask() }) else {
        fatalError("Nothing was completed yet we were woken up")
      }

      if let completedHandle = self.allTasks.removeValue(forKey: completedTaskID) {
        return await try completedHandle.get()
      } else {
        fatalError("Completion for task ID \(completedTaskID) not present in allTasks: \(self.allTasks)!")
      }
    }

    /// Query whether the group has any remaining tasks.
    ///
    /// Task groups are always empty upon entry to the `withGroup` body, and
    /// become empty again when `withGroup` returns (either by awaiting on all
    /// pending tasks or cancelling them).
    ///
    /// - Returns: `true` if the group has no pending tasks, `false` otherwise.
    public var isEmpty: Bool {
      fatalError("\(#function) not implemented yet") // TODO: implement via a Status property
    }

    /// Cancel all the remaining tasks in the group.
    ///
    /// A cancelled group will not will NOT accept new tasks being added into it.
    ///
    /// Any results, including errors thrown by tasks affected by this
    /// cancellation, are silently discarded.
    ///
    /// - SeeAlso: `Task.addCancellationHandler`
    public mutating func cancelAll(file: String = #file, line: UInt = #line) {
//      // TODO: implement this
//      fatalError("\(#function) not implemented yet")

//      for (id, handle) in self.pendingTasks {
//        handle.cancel()
//      }
//      self.pendingTasks = [:]
    }
  }
}
