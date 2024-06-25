// RUN: %target-run-simple-swift( -Xfrontend -disable-availability-checking %import-libdispatch -parse-as-library )

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: libdispatch

// REQUIRES: concurrency_runtime
// UNSUPPORTED: back_deployment_runtime

import Dispatch
import StdlibUnittest
import _Concurrency

final class QueueSerialExecutor: SerialExecutor {
  let queue: DispatchQueue

  init(_ queue: DispatchQueue) {
    self.queue = queue
  }

  public func enqueue(_ _job: consuming ExecutorJob) {
    let job = UnownedJob(_job)
    queue.async {
      job.runSynchronously(on: self.asUnownedSerialExecutor())
    }
  }

  func asUnownedSerialExecutor() -> UnownedSerialExecutor {
    UnownedSerialExecutor(ordinary: self)
  }
}

final class QueueTaskExecutor: TaskExecutor {
  let queue: DispatchQueue

  init(_ queue: DispatchQueue) {
    self.queue = queue
  }

  public func enqueue(_ _job: consuming ExecutorJob) {
    fatalError("Should not be used when enqueue(_:isolatedTo:) is present")
  }

  public func enqueue(_ _job: consuming ExecutorJob, isolatedTo unownedSerialExecutor: UnownedSerialExecutor) {
    let job = UnownedJob(_job)
    queue.async {
      job.runSynchronously(
        isolatedTo: unownedSerialExecutor,
        taskExecutor: self.asUnownedTaskExecutor())
    }
  }
}

actor ThreaddyTheDefaultActor {
  func actorIsolated(expectedExecutor: QueueTaskExecutor) async {
    self.assertIsolated()
    dispatchPrecondition(condition: .onQueue(expectedExecutor.queue))
  }
}

actor CharlieTheCustomExecutorActor {
  let executor: QueueSerialExecutor

  init(executor: QueueSerialExecutor) {
    self.executor = executor
  }

  nonisolated var unownedExecutor: UnownedSerialExecutor {
    self.executor.asUnownedSerialExecutor()
  }

  func actorIsolated(expectedExecutor: QueueSerialExecutor,
                     notExpectedExecutor: QueueTaskExecutor) async {
    self.assertIsolated()
    dispatchPrecondition(condition: .onQueue(expectedExecutor.queue))
    dispatchPrecondition(condition: .notOnQueue(notExpectedExecutor.queue))
  }
}

@main struct Main {
  static func main() async {
    let tests = TestSuite("\(#fileID)")

    tests.test("'default actor' should execute on present task executor preference, and keep isolation") {
      let queue = DispatchQueue(label: "example-queue")
      let executor = QueueTaskExecutor(queue)

      let defaultActor = ThreaddyTheDefaultActor()

      await Task(executorPreference: executor) {
        dispatchPrecondition(condition: .onQueue(executor.queue))
        await defaultActor.actorIsolated(expectedExecutor: executor)
      }
        .value

      await withTaskExecutorPreference(executor) {
        await defaultActor.actorIsolated(expectedExecutor: executor)
      }
    }

    tests.test("'custom executor actor' should NOT execute on present task executor preference, and keep isolation") {
      let serialExecutor = QueueSerialExecutor(DispatchQueue(label: "serial-exec-queue"))
      let taskExecutor = QueueTaskExecutor(DispatchQueue(label: "task-queue"))

      let customActor = CharlieTheCustomExecutorActor(executor: serialExecutor)

      await Task(executorPreference: taskExecutor) {
        dispatchPrecondition(condition: .onQueue(taskExecutor.queue))
        await customActor.actorIsolated(
          expectedExecutor: serialExecutor,
          notExpectedExecutor: taskExecutor)
      }
        .value

      await withTaskExecutorPreference(taskExecutor) {
        await customActor.actorIsolated(
          expectedExecutor: serialExecutor,
          notExpectedExecutor: taskExecutor)
      }
    }

    await runAllTestsAsync()
  }
}
