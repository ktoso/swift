// RUN: %target-typecheck-verify-swift -enable-experimental-concurrency
// REQUIRES: concurrency

actor class SomeActor { }

// ==== ------------------------------------------------------------------------
// MARK: Declaring distributed actors

// GOOD:
@distributed actor class SomeDistributedActor_0 { }

// BAD:
@distributed class SomeDistributedActor_1 { } // expected-error{{'@distributed' can only be applied to 'actor class' definitions, and distributed actor isolated async functions}}
@distributed struct SomeDistributedActor_2 { } // expected-error{{'@distributedActor' attribute cannot be applied to this declaration}}
@distributed enum SomeDistributedActor_3 { } // expected-error{{'@distributedActor' attribute cannot be applied to this declaration}}

// ==== ------------------------------------------------------------------------
// MARK: Declaring distributed functions

// NOTE: not distributed actor, so cannot have any distributed functions
actor class SomeDistributedActor_4 {
  @distributed func nope() -> Int { 42 } // expected-error{{'@distributed' actor-isolated function must be async}}
  @distributed func nopeAsync() async -> Int { 42 }
}

struct SomeDistributedActor_5 {
  @distributed func nope() -> Int { 42 } // expected-error{{NO}}
  @distributed func nopeAsync() async -> Int { 42 } // expected-error{{'@distributed' function can only be declared within '@distributed actor class'}}
}

@distributed
actor class SomeDistributedActor_6 {
  // ==== ----------------------------------------------------------------------
  // BAD:
//  @distributed func nope() -> Int { 42 } // must be async

  // ==== ----------------------------------------------------------------------
  // OK:
  @distributed func nopeAsync() async -> Int { 42 } // ok
}
