// RUN: %target-swift-frontend -primary-file %s -emit-ir -enable-builtin-module -Xcc -Xclang -Xcc -fptrauth-function-pointer-type-discrimination | %FileCheck %s --check-prefix=CHECK

// REQUIRES: concurrency
// REQUIRES: CPU=arm64e

import Builtin

@_silgen_name("swift_task_future_wait_throwing")
public func _taskFutureThrowing<T>(_ task: Builtin.NativeObject) async throws -> T

@_silgen_name("swift_taskGroup_wait_next_throwing")
public func _taskGroupGetThrowing<T>(_ task: Builtin.RawPointer) async throws -> T?

@_silgen_name("swift_asyncLet_get_throwing")
public func _taskAsyncLetGetThrowing<T>(_ task: Builtin.RawPointer) async throws -> T

// Throwing entry: signs continuation with discriminator 29656
// CHECK-LABEL: define swifttailcc void @"$s35continuation_fptrauth_discriminator8testThisyyBp_BotYaF"(ptr swiftasync %0, ptr %1, ptr %2)
// CHECK: [[signed:%[0-9]+]] = call i64 @llvm.ptrauth.sign(i64 %{{[0-9]+}}, i32 0, i64 29656)
// CHECK: [[signed_cast:%[0-9]+]] = inttoptr i64 [[signed]] to ptr
// CHECK: musttail call swifttailcc void @swift_task_future_wait_throwing(ptr noalias %{{[0-9]+}}, ptr swiftasync %{{[0-9]+}}, ptr %2, ptr [[signed_cast]], ptr %{{[0-9]+}})

// Throwing TY1_: signs continuation with discriminator 29656
// CHECK-LABEL: define internal swifttailcc void @"$s35continuation_fptrauth_discriminator8testThisyyBp_BotYaFTY1_"(ptr swiftasync %0)
// CHECK: [[signed:%[0-9]+]] = call i64 @llvm.ptrauth.sign(i64 %{{[0-9]+}}, i32 0, i64 29656)
// CHECK: [[signed_cast:%[0-9]+]] = inttoptr i64 [[signed]] to ptr
// CHECK: musttail call swifttailcc void @swift_taskGroup_wait_next_throwing(ptr noalias %{{[0-9]+}}, ptr swiftasync %{{[0-9]+}}, ptr %{{.*}}, ptr [[signed_cast]], ptr %{{[0-9]+}})

// Throwing TY3_: signs continuation with discriminator 29656
// CHECK-LABEL: define internal swifttailcc void @"$s35continuation_fptrauth_discriminator8testThisyyBp_BotYaFTY3_"(ptr swiftasync %0)
// CHECK: [[signed:%[0-9]+]] = call i64 @llvm.ptrauth.sign(i64 %{{[0-9]+}}, i32 0, i64 29656)
// CHECK: [[signed_cast:%[0-9]+]] = inttoptr i64 [[signed]] to ptr
// CHECK: musttail call swifttailcc void @swift_asyncLet_get_throwing(ptr noalias %{{[0-9]+}}, ptr swiftasync %{{[0-9]+}}, ptr %{{.*}}, ptr [[signed_cast]], ptr %{{[0-9]+}})

public func testThis(_ task: Builtin.RawPointer, _ obj: Builtin.NativeObject) async {
  do {
    let _ : Int = try await _taskFutureThrowing(obj)
    let _ : Int? = try await _taskGroupGetThrowing(task)
    let _ : Int = try await _taskAsyncLetGetThrowing(task)
  } catch _ {
  }
}

@_silgen_name("swift_task_future_wait")
public func _taskFuture<T>(_ task: Builtin.NativeObject) async -> T

@_silgen_name("swift_asyncLet_get")
public func _taskAsyncLetGet<T>(_ task: Builtin.RawPointer) async -> T

@_silgen_name("swift_asyncLet_finish")
public func _taskAsyncLetFinish<T>(_ task: Builtin.RawPointer) async -> T

// Non-throwing entry: signs continuation with discriminator 10942
// CHECK-LABEL: define swifttailcc void @"$s35continuation_fptrauth_discriminator19testThisNonThrowingyyBp_BotYaF"(ptr swiftasync %0, ptr %1, ptr %2)
// CHECK: [[signed:%[0-9]+]] = call i64 @llvm.ptrauth.sign(i64 %{{[0-9]+}}, i32 0, i64 10942)
// CHECK: [[signed_cast:%[0-9]+]] = inttoptr i64 [[signed]] to ptr
// CHECK: musttail call swifttailcc void @swift_task_future_wait(ptr noalias %{{[0-9]+}}, ptr swiftasync %{{[0-9]+}}, ptr %2, ptr [[signed_cast]], ptr %{{[0-9]+}})

// Non-throwing TY1_: signs continuation with discriminator 10942
// CHECK-LABEL: define internal swifttailcc void @"$s35continuation_fptrauth_discriminator19testThisNonThrowingyyBp_BotYaFTY1_"(ptr swiftasync %0)
// CHECK: [[signed:%[0-9]+]] = call i64 @llvm.ptrauth.sign(i64 %{{[0-9]+}}, i32 0, i64 10942)
// CHECK: [[signed_cast:%[0-9]+]] = inttoptr i64 [[signed]] to ptr
// CHECK: musttail call swifttailcc void @swift_asyncLet_get(ptr noalias %{{[0-9]+}}, ptr swiftasync %{{[0-9]+}}, ptr %{{.*}}, ptr [[signed_cast]], ptr %{{[0-9]+}})

// Non-throwing TY3_: signs continuation with discriminator 10942
// CHECK-LABEL: define internal swifttailcc void @"$s35continuation_fptrauth_discriminator19testThisNonThrowingyyBp_BotYaFTY3_"(ptr swiftasync %0)
// CHECK: [[signed:%[0-9]+]] = call i64 @llvm.ptrauth.sign(i64 %{{[0-9]+}}, i32 0, i64 10942)
// CHECK: [[signed_cast:%[0-9]+]] = inttoptr i64 [[signed]] to ptr
// CHECK: musttail call swifttailcc void @swift_asyncLet_finish(ptr noalias %{{[0-9]+}}, ptr swiftasync %{{[0-9]+}}, ptr %{{.*}}, ptr [[signed_cast]], ptr %{{[0-9]+}})

public func testThisNonThrowing(_ task: Builtin.RawPointer, _ obj: Builtin.NativeObject) async {
  let _ : Int = await _taskFuture(obj)
  let _ : Int = await _taskAsyncLetGet(task)
  let _ : Int = await _taskAsyncLetFinish(task)
}
