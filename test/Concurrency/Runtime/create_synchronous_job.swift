// RUN: %target-run-simple-swift( -Xfrontend -disable-availability-checking %import-libdispatch -Xfrontend -enable-builtin-module -parse-as-library) | %FileCheck %s --dump-input=always

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: libdispatch

// REQUIRES: concurrency_runtime
// UNSUPPORTED: back_deployment_runtime

import Builtin
import Dispatch

@_silgen_name("swift_task_enqueueGlobal")
func _enqueueJobGlobal(_ task: Builtin.Job)

@main struct Main {
  static func main() async {
    print("--- test_run_once")
    // CHECK-LABEL: --- test_run_once

    let sema = DispatchSemaphore(value: 0)
    let job = Builtin.createSynchronousJob(priority: UInt8(0)) {
      print("closure ran")
      sema.signal()
    }
    _enqueueJobGlobal(job)
    sema.wait()
    print("job finished")
    // CHECK: closure ran
    // CHECK: job finished

    print("--- test_capture_released")
    // CHECK-LABEL: --- test_capture_released
    do {
      final class Trace {
        deinit { print("Trace deinit") }
      }
      let sema2 = DispatchSemaphore(value: 0)
      let trace = Trace()
      let job2 = Builtin.createSynchronousJob(priority: UInt8(0)) {
        // Force a use of the captured object so the closure actually
        // retains it.
        _ = trace
        print("closure2 ran")
        sema2.signal()
      }
      _enqueueJobGlobal(job2)
      sema2.wait()
      // CHECK: closure2 ran
      // CHECK: Trace deinit
    }

    print("done")
    // CHECK: done
  }
}
