// RUN: %target-typecheck-verify-swift -enable-experimental-concurrency
// REQUIRES: concurrency

// Test that @_reentrant attribute parses correctly

// @_reentrant(never) on actor class
@_reentrant(never)
actor NonReentrantActor {
  var value: Int = 0

  func increment() async {
    value += 1
  }
}

// @_reentrant(never) on individual method
actor PartiallyReentrantActor {
  var value: Int = 0

  @_reentrant(never)
  func criticalSection() async {
    value += 1
  }

  func normalMethod() async {
    value += 10
  }
}

// @_reentrant without argument (default)
@_reentrant
actor DefaultReentrantActor {
  var value: Int = 0
}

// Error cases

// @_reentrant(never) on non-actor class - should be allowed for now (checking deferred)
@_reentrant(never)
class RegularClass {} // No error expected yet - semantic checking not implemented

// @_reentrant with invalid argument
@_reentrant(invalid) // expected-error {{unknown option 'invalid' for attribute '_reentrant'}}
actor InvalidActor {}
