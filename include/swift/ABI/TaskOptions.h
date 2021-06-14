//===--- Task.h - ABI structures for asynchronous tasks ---------*- C++ -*-===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
//
// Swift ABI describing tasks.
//
//===----------------------------------------------------------------------===//

#ifndef SWIFT_ABI_TASK_H
#define SWIFT_ABI_TASK_H

#include "swift/ABI/TaskLocal.h"
#include "swift/ABI/Executor.h"
#include "swift/ABI/HeapObject.h"
#include "swift/ABI/Metadata.h"
#include "swift/ABI/MetadataValues.h"
#include "swift/Runtime/Config.h"
#include "swift/Basic/STLExtras.h"

namespace swift {

// ==== ------------------------------------------------------------------------
// ==== Task Options, for creating and waiting on tasks

/// Flags for task option records.
class TaskOptionRecordFlags : public FlagSet<size_t> {
public:
  enum {
    Kind           = 0,
    Kind_width     = 8,
  };

  explicit TaskOptionRecordFlags(size_t bits) : FlagSet(bits) {}
  constexpr TaskOptionRecordFlags() {}
  TaskOptionRecordFlags(TaskOptionRecordKind kind) {
    setKind(kind);
  }

  FLAGSET_DEFINE_FIELD_ACCESSORS(Kind, Kind_width, TaskOptionRecordKind,
                                 getKind, setKind)
};

/// The abstract base class for all options that may be used
/// to configure a newly spawned task.
class TaskOptionRecord {
public:
  TaskOptionRecordFlags Flags;
  TaskOptionRecord *Parent;

  TaskOptionRecord(TaskOptionRecordKind kind,
                   TaskOptionRecord *parent = nullptr)
  : Flags(kind) {
    Parent = parent;
  }

  TaskOptionRecord(const TaskOptionRecord &) = delete;
  TaskOptionRecord &operator=(const TaskOptionRecord &) = delete;

  TaskOptionRecordKind getKind() const {
    return Flags.getKind();
  }

  TaskOptionRecord *getParent() const {
    return Parent;
  }

};

/// Task option to specify on what executor the task should be executed.
///
/// Not passing this option implies that that a "best guess" or good default
/// executor should be used instead, most often this may mean the global
/// concurrent executor, or the enclosing actor's executor.
class ExecutorTaskOptionRecord : public TaskOptionRecord {
  ExecutorRef *Executor;

public:
  ExecutorTaskOptionRecord(ExecutorRef *executor)
    : TaskOptionRecord(TaskOptionRecordKind::Executor),
      Executor(executor) {}

  ExecutorRef *getExecutor() const {
    return Executor;
  }
};

// ==== ------------------------------------------------------------------------

/// An asynchronous context within a task.  Generally contexts are
/// allocated using the task-local stack alloc/dealloc operations, but
/// there's no guarantee of that, and the ABI is designed to permit
/// contexts to be allocated within their caller's frame.
class alignas(MaximumAlignment) AsyncContext {
public:
  /// The parent context.
  AsyncContext * __ptrauth_swift_async_context_parent Parent;

  /// The function to call to resume running in the parent context.
  /// Generally this means a semantic return, but for some temporary
  /// translation contexts it might mean initiating a call.
  ///
  /// Eventually, the actual type here will depend on the types
  /// which need to be passed to the parent.  For now, arguments
  /// are always written into the context, and so the type is
  /// always the same.
  TaskContinuationFunction * __ptrauth_swift_async_context_resume
    ResumeParent;

  /// Flags describing this context.
  ///
  /// Note that this field is only 32 bits; any alignment padding
  /// following this on 64-bit platforms can be freely used by the
  /// function.  If the function is a yielding function, that padding
  /// is of course interrupted by the YieldToParent field.
  AsyncContextFlags Flags;

  AsyncContext(AsyncContextFlags flags,
               TaskContinuationFunction *resumeParent,
               AsyncContext *parent)
    : Parent(parent), ResumeParent(resumeParent),
      Flags(flags) {}

  AsyncContext(const AsyncContext &) = delete;
  AsyncContext &operator=(const AsyncContext &) = delete;

  /// Perform a return from this context.
  ///
  /// Generally this should be tail-called.
  SWIFT_CC(swiftasync)
  void resumeParent() {
    // TODO: destroy context before returning?
    // FIXME: force tail call
    return ResumeParent(Parent);
  }
};

/// An async context that supports yielding.
class YieldingAsyncContext : public AsyncContext {
public:
  /// The function to call to temporarily resume running in the
  /// parent context.  Generally this means a semantic yield.
  TaskContinuationFunction * __ptrauth_swift_async_context_yield
    YieldToParent;

  YieldingAsyncContext(AsyncContextFlags flags,
                       TaskContinuationFunction *resumeParent,
                       TaskContinuationFunction *yieldToParent,
                       AsyncContext *parent)
    : AsyncContext(flags, resumeParent, parent),
      YieldToParent(yieldToParent) {}

  static bool classof(const AsyncContext *context) {
    return context->Flags.getKind() == AsyncContextKind::Yielding;
  }
};

/// An async context that can be resumed as a continuation.
class ContinuationAsyncContext : public AsyncContext {
public:
  /// An atomic object used to ensure that a continuation is not
  /// scheduled immediately during a resume if it hasn't yet been
  /// awaited by the function which set it up.
  std::atomic<ContinuationStatus> AwaitSynchronization;

  /// The error result value of the continuation.
  /// This should be null-initialized when setting up the continuation.
  /// Throwing resumers must overwrite this with a non-null value.
  SwiftError *ErrorResult;

  /// A pointer to the normal result value of the continuation.
  /// Normal resumers must initialize this before resuming.
  OpaqueValue *NormalResult;

  /// The executor that should be resumed to.
  ExecutorRef ResumeToExecutor;

  void setErrorResult(SwiftError *error) {
    ErrorResult = error;
  }

  static bool classof(const AsyncContext *context) {
    return context->Flags.getKind() == AsyncContextKind::Continuation;
  }
};

/// An asynchronous context within a task that describes a general "Future".
/// task.
///
/// This type matches the ABI of a function `<T> () async throws -> T`, which
/// is the type used by `detach` and `Task.group.add` to create
/// futures.
class FutureAsyncContext : public AsyncContext {
public:
  using AsyncContext::AsyncContext;
};

/// This matches the ABI of a closure `() async throws -> ()`
using AsyncVoidClosureEntryPoint =
  SWIFT_CC(swiftasync)
  void (SWIFT_ASYNC_CONTEXT AsyncContext *, SWIFT_CONTEXT void *);

/// This matches the ABI of a closure `<T>() async throws -> T`
using AsyncGenericClosureEntryPoint =
    SWIFT_CC(swiftasync)
    void(OpaqueValue *,
         SWIFT_ASYNC_CONTEXT AsyncContext *, SWIFT_CONTEXT void *);

/// This matches the ABI of the resume function of a closure
///  `() async throws -> ()`.
using AsyncVoidClosureResumeEntryPoint =
  SWIFT_CC(swiftasync)
  void(SWIFT_ASYNC_CONTEXT AsyncContext *, SWIFT_CONTEXT SwiftError *);

class AsyncContextPrefix {
public:
  // Async closure entry point adhering to compiler calling conv (e.g directly
  // passing the closure context instead of via the async context)
  AsyncVoidClosureEntryPoint *__ptrauth_swift_task_resume_function
      asyncEntryPoint;
  void *closureContext;
  SwiftError *errorResult;
};

/// Storage that is allocated before the AsyncContext to be used by an adapter
/// of Swift's async convention and the ResumeTask interface.
class FutureAsyncContextPrefix {
public:
  OpaqueValue *indirectResult;
  // Async closure entry point adhering to compiler calling conv (e.g directly
  // passing the closure context instead of via the async context)
  AsyncGenericClosureEntryPoint *__ptrauth_swift_task_resume_function
      asyncEntryPoint;
  void *closureContext;
  SwiftError *errorResult;
};

} // end namespace swift

#endif
