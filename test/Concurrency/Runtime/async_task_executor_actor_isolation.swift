// RUN: %target-run-simple-swift( -Xfrontend -disable-availability-checking %import-libdispatch -parse-as-library )

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: libdispatch

// REQUIRES: concurrency_runtime
// UNSUPPORTED: back_deployment_runtime

import Dispatch
import StdlibUnittest
import _Concurrency

//final class NaiveQueueExecutor: TaskExecutor, SerialExecutor {
//  let queue: DispatchQueue
//
//  init(_ queue: DispatchQueue) {
//    self.queue = queue
//  }
//
//  public func enqueue(_ _job: consuming ExecutorJob) {
//    let job = UnownedJob(_job)
//    queue.async {
//      job.runSynchronously(
//        isolatedTo: self.asUnownedSerialExecutor(),
//        taskExecutor: self.asUnownedTaskExecutor())
//    }
//  }
//
//  @inlinable
//  public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
//    UnownedSerialExecutor(complexEquality: self)
//  }
//
//  @inlinable
//  public func asUnownedTaskExecutor() -> UnownedTaskExecutor {
//    UnownedTaskExecutor(ordinary: self)
//  }
//}

// Define custom executor
final class ConcurrentQueueExecutor: Sendable, TaskExecutor {
  let queue = DispatchQueue(label: "ConcurrentQueueExecutor", attributes: [.concurrent])

  func enqueue(_ job: UnownedJob) {
    queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
  }
}

// Define a nice little default actor
actor MyActor {
  func sayHello() {
    // I should always see "hello" followed by "world",
    // but if I remove the isolation check I get
    // "hello" "hello" "world" "world"
    assertIsolated()
    print("hello")
    usleep(1_000_000)
    print("world")
  }
}

@main struct Main {

  static func main() async {
    let executor = ConcurrentQueueExecutor()
    let actor = MyActor()

    let b = Task(executorPreference: executor) {
      await actor.sayHello()
    }

    let a = Task {
      await actor.sayHello()
    }

    _ = await (a.result, b.result)

  }
}
