// RUN: %target-swift-frontend -primary-file %s -enable-builtin-module -emit-ir  -target %target-swift-5.1-abi-triple | %FileCheck %s --check-prefix=CHECK --check-prefix=CHECK-%target-ptrsize
// RUN: %target-swift-frontend -primary-file %s -enable-builtin-module -emit-ir  -target %target-swift-5.1-abi-triple -enable-library-evolution

// REQUIRES: concurrency
// UNSUPPORTED: CPU=wasm32

import Builtin

// CHECK: "$s5async1fyyYaF"
public func f() async { }

// CHECK: "$s5async1gyyYaKF"
public func g() async throws { }

// CHECK: "$s5async1hyyS2iYbXEF"
public func h(_: @Sendable (Int) -> Int) { }

@_silgen_name("swift_task_future_wait_throwing")
public func _taskFutureGetThrowing<T>(_ task: Builtin.NativeObject) async throws -> T

// CHECK: define{{.*}} swift{{(tail)?}}cc void @"$s5async8testThisyyBonYaF"(ptr swiftasync %0{{.*}}
// CHECK-NOT: @swift_task_alloc
// CHECK: {{(must)?}}tail call swift{{(tail)?}}cc void @swift_task_future_wait_throwing(ptr {{.*}}, ptr {{.*}}, ptr {{.*}}, ptr {{.*}}, ptr {{.*}})
public func testThis(_ task: __owned Builtin.NativeObject) async {
  do {
    let _ : Int = try await _taskFutureGetThrowing(task)
  } catch _ {
    print("error")
  }
}


public protocol P {}

struct I : P {
  var x = 0
}

public struct S {
  public func callee() async -> some P {
    return I()
  }
  // We used to assert on this in resilient mode due to mismatch function
  // pointers.
  public func caller() async -> some P {
      return await callee()
  }
}

// ==== -----------------------------------------------------------------------
// MARK: Builtin.createSynchronousJob

// IRGen coverage for `Builtin.createSynchronousJob` (backs the
// `withDeadline` timer / general fire-once synchronous work item on an
// executor). Verifies the builtin lowers to a direct call to the
// `swift_job_createSynchronous` runtime entry point, with the closure's
// `(fn, ctx)` pair forwarded as `(context, invoke)` args.

// CHECK-LABEL: define{{.*}} swiftcc ptr @"$s5async26emptySynchronousJobBuiltinBjyF"
// CHECK: call{{.*}} swiftcc ptr @swift_job_createSynchronous(i{{32|64}} 0, ptr null, ptr @"$s5async26emptySynchronousJobBuiltinBjyFyycfU_{{(.ptrauth)?}}"
// CHECK: ret ptr
public func emptySynchronousJobBuiltin() -> Builtin.Job {
  return Builtin.createSynchronousJob(priority: UInt8(0)) { }
}

// A captured heap object is retained into the closure's context; the
// context pointer is what shows up as the middle arg to the runtime call.
public class SynchronousJobTrace {}

// CHECK-LABEL: define{{.*}} swiftcc ptr @"$s5async23capturingSynchronousJobBjyF"
// CHECK: call{{.*}} swiftcc ptr @swift_job_createSynchronous(i{{32|64}} 0, ptr %{{[0-9]+}}, ptr @"$s5async23capturingSynchronousJobBjyFyycfU_TA{{(.ptrauth)?}}"
// CHECK: ret ptr
public func capturingSynchronousJob() -> Builtin.Job {
  let trace = SynchronousJobTrace()
  return Builtin.createSynchronousJob(priority: UInt8(0)) {
    _ = trace
  }
}
