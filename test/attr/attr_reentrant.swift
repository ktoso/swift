// RUN: %target-typecheck-verify-swift -enable-experimental-feature ActorReentrancyControl
// REQUIRES: concurrency

// Test that @_reentrant attribute parses correctly and semantic validation works.

// @_reentrant(never) on actor class - OK
@_reentrant(never)
actor NonReentrantActor {
  var value: Int = 0

  func increment() async {
    value += 1
  }
}

// @_reentrant(never) on individual method within an actor - OK
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

// @_reentrant without argument (default) on actor - OK
@_reentrant
actor DefaultReentrantActor {
  var value: Int = 0
}

// Error: @_reentrant(never) on non-actor class
@_reentrant(never)
class RegularClass {} // expected-error {{'@_reentrant' can only be applied to an actor declaration or a method within an actor}}

// Error: @_reentrant with invalid argument
@_reentrant(invalid) // expected-error {{unknown option 'invalid' for attribute '_reentrant'}}
actor InvalidActor {}

// Error: @_reentrant(never) on a method inside a non-actor class
class RegularClass2 {
  @_reentrant(never)
  func foo() async {} // expected-error {{'@_reentrant' can only be applied to an actor declaration or a method within an actor}}
}

// Error: @_reentrant(never) on a free function
@_reentrant(never)
func freeFunction() async {} // expected-error {{'@_reentrant' attribute cannot be applied to this declaration}}
