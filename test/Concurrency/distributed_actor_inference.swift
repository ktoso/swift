// RUN: %target-typecheck-verify-swift -enable-experimental-concurrency
// REQUIRES: concurrency

actor class SomeActor { }

@distributedActor actor class SomeDistributedActor { }

