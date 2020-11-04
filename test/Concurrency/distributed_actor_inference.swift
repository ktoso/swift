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
//
//// NOTE: not distributed actor, so cannot have any distributed functions
//actor class SomeDistributedActor_4 {
//  @distributed func nope() -> Int { 42 }
//  @distributed func nopeAsync() async -> Int { 42 }
//}

@distributed
actor class SomeDistributedActor_5 {
  // ==== ----------------------------------------------------------------------
  // BAD:
//  @distributed func nope() -> Int { 42 } // must be async

  // ==== ----------------------------------------------------------------------
  // OK:
  @distributed func nopeAsync() async -> Int { 42 } // ok
}
