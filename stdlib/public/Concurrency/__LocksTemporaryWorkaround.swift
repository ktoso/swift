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
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#else
import Glibc
#endif

final class _Mutex {
  @usableFromInline
  var mutex: pthread_mutex_t = pthread_mutex_t()

  public init() {
    var attr: pthread_mutexattr_t = pthread_mutexattr_t()
    pthread_mutexattr_init(&attr)
    pthread_mutexattr_settype(&attr, Int32(PTHREAD_MUTEX_RECURSIVE))

    let error = pthread_mutex_init(&self.mutex, &attr)
    pthread_mutexattr_destroy(&attr)

    switch error {
    case 0:
      return
    default:
      fatalError("Could not create mutex: \(error)")
    }
  }

  deinit {
    pthread_mutex_destroy(&mutex)
  }

  @inlinable
  public func lock() {
    let error = pthread_mutex_lock(&self.mutex)

    switch error {
    case 0:
      return
    case EDEADLK:
      fatalError("Mutex could not be acquired because it would have caused a deadlock")
    default:
      fatalError("Failed with unspecified error: \(error)")
    }
  }

  @inlinable
  public func unlock() {
    let error = pthread_mutex_unlock(&self.mutex)

    switch error {
    case 0:
      return
    case EPERM:
      fatalError("Mutex could not be unlocked because it is not held by the current thread")
    default:
      fatalError("Unlock failed with unspecified error: \(error)")
    }
  }

  @inlinable
  public func tryLock() -> Bool {
    let error = pthread_mutex_trylock(&self.mutex)

    switch error {
    case 0:
      return true
    case EBUSY:
      return false
    case EDEADLK:
      fatalError("Mutex could not be acquired because it would have caused a deadlock")
    default:
      fatalError("Failed with unspecified error: \(error)")
    }
  }

  @inlinable
  public func synchronized<A>(_ f: () -> A) -> A {
    self.lock()

    defer {
      unlock()
    }

    return f()
  }

  @inlinable
  public func synchronized<A>(_ f: () throws -> A) throws -> A {
    self.lock()

    defer {
      unlock()
    }

    return try f()
  }
}
