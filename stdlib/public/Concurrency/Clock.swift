//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
import Swift

/// A mechanism in which to measure time, and delay work until a given point
/// in time.
///
/// Types that conform to the `Clock` protocol define a concept of "now" which
/// is the specific instant in time that property is accessed. Any pair of calls
/// to the `now` property may have a minimum duration between them - this
/// minimum resolution is exposed by the `minimumResolution` property to inform
/// any user of the type the expected granularity of accuracy.
///
/// One of the primary uses for clocks is to schedule task sleeping. This method
/// resumes the calling task after a given deadline has been met or passed with
/// a given tolerance value. The tolerance is expected as a leeway around the
/// deadline. The clock may reschedule tasks within the tolerance to ensure
/// efficient execution of resumptions by reducing potential operating system
/// wake-ups. If no tolerance is specified (i.e. nil is passed in) the sleep
/// function is expected to schedule with a default tolerance strategy.
///
/// For more information about specific clocks see `ContinuousClock` and
/// `SuspendingClock`.
@available(StdlibDeploymentTarget 5.7, *)
public protocol Clock<Duration>: Sendable {
  associatedtype Duration
  associatedtype Instant: InstantProtocol where Instant.Duration == Duration

  var now: Instant { get }
  var minimumResolution: Instant.Duration { get }

#if !$Embedded && !SWIFT_STDLIB_TASK_TO_THREAD_MODEL_CONCURRENCY
  func sleep(until deadline: Instant, tolerance: Instant.Duration?) async throws

  /// Run `body` under this clock's deadline enforcement.
  ///
  /// Clocks that know how to schedule work against their own timeline (for
  /// example, ``ContinuousClock`` and ``SuspendingClock``) override this to
  /// arm a cancellation timer via their clock-specific executor. The default
  /// implementation runs `body` without any timer; observers of the deadline
  /// status record pushed by the top-level ``withDeadline(_:tolerance:clock:body:)``
  /// still see the deadline via `Task.hasActiveDeadline`, so cooperative
  /// cancellation checks continue to work for custom clocks.
  @available(StdlibDeploymentTarget 6.5, *)
  nonisolated(nonsending)
  func withDeadline<Return: ~Copyable, Failure: Error>(
    _ expiration: Instant,
    tolerance: Instant.Duration?,
    body: nonisolated(nonsending) () async throws(Failure) -> Return
  ) async throws(Failure) -> Return
#endif
}

#if !$Embedded && !SWIFT_STDLIB_TASK_TO_THREAD_MODEL_CONCURRENCY
@available(StdlibDeploymentTarget 6.5, *)
extension Clock {
  /// Default: no clock-specific executor is known, so run `body` without
  /// arming a timer. The deadline status record pushed by the top-level
  /// ``withDeadline(_:tolerance:clock:body:)`` is still visible inside
  /// `body`, so cooperative cancellation via `Task.hasActiveDeadline` /
  /// `Task.isCancelled` still works for custom clocks that opt into
  /// observation.
  public nonisolated(nonsending)
  func withDeadline<Return: ~Copyable, Failure: Error>(
    _ expiration: Instant,
    tolerance: Instant.Duration?,
    body: nonisolated(nonsending) () async throws(Failure) -> Return
  ) async throws(Failure) -> Return {
    try await body()
  }
}
#endif

@available(StdlibDeploymentTarget 5.7, *)
extension Clock {
  /// Measure the elapsed time to execute a closure.
  ///
  ///       let clock = ContinuousClock()
  ///       let elapsed = clock.measure {
  ///          someWork()
  ///       }
  @available(StdlibDeploymentTarget 5.7, *)
  public func measure(_ work: () throws -> Void) rethrows -> Instant.Duration {
    let start = now
    try work()
    let end = now
    return start.duration(to: end)
  }

  /// Measure the elapsed time to execute an asynchronous closure.
  ///
  ///       let clock = ContinuousClock()
  ///       let elapsed = await clock.measure {
  ///          await someWork()
  ///       }
  @available(StdlibDeploymentTarget 5.7, *)
  @export(implementation)
  public nonisolated(nonsending) func measure(
    _ work: nonisolated(nonsending) () async throws -> Void
  ) async rethrows -> Instant.Duration {
    let start = now
    try await work()
    let end = now
    return start.duration(to: end)
  }

  @available(StdlibDeploymentTarget 5.7, *)
  @export(implementation)
  @available(*, deprecated, message: "Replaced by nonisolated(nonsending) overload")
  public func measure(
    isolation: isolated (any Actor)? = #isolation,
    _ work: () async throws -> Void
  ) async rethrows -> Instant.Duration {
    let start = now
    try await work()
    let end = now
    return start.duration(to: end)
  }

  // Note: hack to stage out @_unsafeInheritExecutor forms of various functions
  // in favor of #isolation. The _unsafeInheritExecutor_ prefix is meaningful
  // to the type checker.
  //
  // This function also doubles as an ABI-compatibility shim predating the
  // introduction of #isolation.
  @available(StdlibDeploymentTarget 5.7, *)
  @_silgen_name("$ss5ClockPsE7measurey8DurationQzyyYaKXEYaKF")
  @_unsafeInheritExecutor // for ABI compatibility
  public func _unsafeInheritExecutor_measure(
    _ work: () async throws -> Void
  ) async rethrows -> Instant.Duration {
    let start = now
    try await work()
    let end = now
    return start.duration(to: end)
  }
}

#if !$Embedded && !SWIFT_STDLIB_TASK_TO_THREAD_MODEL_CONCURRENCY
@available(StdlibDeploymentTarget 5.7, *)
extension Clock {
  /// Suspends for the given duration.
  ///
  /// Prefer to use the `sleep(until:tolerance:)` method on `Clock` if you have
  /// access to an absolute instant.
  @available(StdlibDeploymentTarget 5.7, *)
  @export(implementation)
  public func sleep(
    for duration: Instant.Duration,
    tolerance: Instant.Duration? = nil
  ) async throws {
    try await sleep(until: now.advanced(by: duration), tolerance: tolerance)
  }
}
#endif

enum _ClockID: Int32 {
  case continuous = 1
  case suspending = 2
  case walltime = 3
}

@nonexhaustive
@available(StdlibDeploymentTarget 6.5, *)
public enum SystemClockID: Int32, Hashable {
  case continuous = 1  // _ClockID.continuous
  case suspending = 2  // _ClockID.suspending
}

@available(StdlibDeploymentTarget 5.7, *)
@_silgen_name("swift_get_time")
internal func _getTime(
  seconds: UnsafeMutablePointer<Int64>,
  nanoseconds: UnsafeMutablePointer<Int64>,
  clock: CInt)

@available(StdlibDeploymentTarget 5.7, *)
@_silgen_name("swift_get_clock_res")
internal func _getClockRes(
  seconds: UnsafeMutablePointer<Int64>,
  nanoseconds: UnsafeMutablePointer<Int64>,
  clock: CInt)

@available(StdlibDeploymentTarget 6.3, *)
@_silgen_name("swift_sleep")
internal func _sleep(
  seconds: Int64,
  nanoseconds: Int64)
