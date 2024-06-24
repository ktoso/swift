// RUN: %target-run-simple-swift( -Xfrontend -disable-availability-checking %import-libdispatch -parse-as-library )

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: libdispatch

// REQUIRES: concurrency_runtime
// UNSUPPORTED: back_deployment_runtime

import Darwin
import Dispatch
import StdlibUnittest
import _Concurrency

final class NaiveQueueExecutor: TaskExecutor {
  let queue: DispatchQueue

  init(_ queue: DispatchQueue) {
    self.queue = queue
  }

  public func enqueue(_ _job: consuming ExecutorJob) {
    fputs("\n\n\n\n Swift enqueue job: job.runSynchronously(on: self.asUnownedTaskExecutor())\n", stderr)
    let job = UnownedJob(_job)
    queue.async {
      job.runSynchronously(on: self.asUnownedTaskExecutor())
    }
  }
  public func enqueue(_ _job: consuming ExecutorJob, isolatedTo unownedSerialExecutor: UnownedSerialExecutor) {
    fputs("\n\n\n\n Swift enqueue job: job.runSynchronously(on: self.asUnownedTaskExecutor())\n", stderr)
    let job = UnownedJob(_job)
    queue.async {
      job.runSynchronously(
        isolatedTo: unownedSerialExecutor,
        taskExecutor: self.asUnownedTaskExecutor())
    }
  }

  public func apiTest(serialExecutor: any SerialExecutor, _ job: consuming ExecutorJob) {
    job.runSynchronously(
      isolatedTo: serialExecutor.asUnownedSerialExecutor(),
      taskExecutor: self.asUnownedTaskExecutor())
  }

}

actor ThreaddyTheDefaultActor {
  func justActorIsolated() async {
    self.assertIsolated()
  }

  func actorIsolated(expectedExecutor: NaiveQueueExecutor) async {
    fputs(">>>>>> INSIDE ACTOR <<<<<\n", stderr)
    self.assertIsolated()
    dispatchPrecondition(condition: .onQueue(expectedExecutor.queue))
  }
}

@main struct Main {

  static func main() async {
    let queue = DispatchQueue(label: "example-queue")
    let executor = NaiveQueueExecutor(queue)

    let defaultActor = ThreaddyTheDefaultActor()

    fputs("\n\n\n\nSTART TASK....\n", stderr)

    await Task(executorPreference: executor) {
//    await Task.detached {

//      dispatchPrecondition(condition: .onQueue(executor.queue))
      await defaultActor.actorIsolated(expectedExecutor: executor)
    }.value

//    await withTaskExecutorPreference(executor) {
//      await defaultActor.actorIsolated(expectedExecutor: executor)
//    }
  }
}
