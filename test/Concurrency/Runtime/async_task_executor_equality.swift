// RUN: %target-run-simple-swift( -Xfrontend -disable-availability-checking %import-libdispatch -parse-as-library )

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: libdispatch

// REQUIRES: concurrency_runtime
// UNSUPPORTED: back_deployment_runtime

import Dispatch
@_spi(ConcurrencyExecutors) import _Concurrency

final class MyTaskExecutor: TaskExecutor, @unchecked Sendable, CustomStringConvertible {
  let queue: DispatchQueue

  init(queue: DispatchQueue) {
    self.queue = queue
  }

  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    queue.async {
      job.runSynchronously(on: self.asUnownedTaskExecutor())
    }
  }

  var description: String {
    "\(Self.self)(\(ObjectIdentifier(self))"
  }
}

nonisolated func nonisolatedAsyncMethod(expectedOn executor: MyTaskExecutor) async {

}

@main struct Main {

  static func main() async {
    let firstExecutor = MyTaskExecutor(queue: DispatchQueue(label: "first"))

    await Task(executorPreference: firstExecutor) {
      withUnsafeCurrentTask { task in
        let unowned = task!.unownedTaskExecutor

        dispatchPrecondition(condition: .onQueue(firstExecutor.queue))
        assert(unowned == firstExecutor.asUnownedTaskExecutor())
      }
    }.value

    await withTaskGroup(of: Void.self) { group in
      group.addTask(executorPreference: firstExecutor) {
        withUnsafeCurrentTask { task in
          dispatchPrecondition(condition: .onQueue(firstExecutor.queue))

          let unowned = task!.unownedTaskExecutor
          assert(unowned == firstExecutor.asUnownedTaskExecutor())
        }
      }
    }
  }
}
