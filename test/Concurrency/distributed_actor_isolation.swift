// RUN: %target-typecheck-verify-swift -enable-experimental-concurrency
// REQUIRES: concurrency

@distributed actor class DistributedActor_1 {
  let name: String = "alice"

  var mutable: String = "alice" // expected -note{{mutable state is only available within the actor instance}}

  func sync() -> Int { // expected -note{{only asynchronous methods can be used outside the actor instance; do you want to add 'async'}}
    42
  }

  func async() async -> Int {
    42
  }

  @distributed func dist() async throws -> Int {
    42
  }
}

@distributed class Base {}
@distributed actor class Bottom: Base {}

actor class Other {
  func test(peer: DistributedActor_1) async throws {
    _ = peer.name // expected-error{{nein}}
//    _ = peer.mutable // expected- error{{actor-isolated property 'mutable' can only be referenced inside the actor}}
//    _ = peer.sync() // expected- error{{actor-isolated instance method 'sync()' can only be referenced inside the actor}}
//
//    _ = await peer.async() // expected -error{{actor-isolated instance method 'dist()' can only be referenced inside the distributed actor}}
//    _ = await try peer.dist() // ok
  }
}
