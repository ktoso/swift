// RUN: %target-typecheck-verify-swift -enable-experimental-concurrency
// REQUIRES: concurrency

actor class LocalActor_1 {
  let name: String = "alice"
  var mutable: String = ""
}

@distributed actor class DistributedActor_1 {
  let name: String = "alice" // expected-note{{mutable state is only available within the actor instance}}

  var mutable: String = "alice" // expected -note{{mutable-state is only available within the actor instance}}

  var computedMutable: String {
    get {
      "hey"
    }
    set {
      _ = newValue
    }
  }

  func sync() -> Int { // expected -note{{only asynchronous methods can be used outside the actor instance; do you want to add 'async'}}
    42
  }

  func async() async -> Int {
    42
  }

  @distributed func dist() async throws -> Int {
    42
  }

  func test() async throws {
    _ = self.name
    _ = self.computedMutable
    _ = self.sync()
    _ = await self.async()
    _ = await try self.dist()
  }
}

func test(
  local: LocalActor_1,
  distributed: DistributedActor_1
) async throws {
  _ = local.name // ok, special case that let constants are okey
  _ = distributed.name // expected-error{{distributed actor-isolated property 'name' can only be referenced inside the distributed actor}}

//    _ = local.mutable // expected- error{{actor-isolated property 'mutable' can only be referenced inside the actor}}
//    _ = distributed.mutable // expected- error{{actor-isolated property 'mutable' can only be referenced inside the actor}}

//    _ = distributed.sync() // expected- error{{actor-isolated instance method 'sync()' can only be referenced inside the actor}}
//
//    _ = await distributed.async() // expected -error{{actor-isolated instance method 'dist()' can only be referenced inside the distributed actor}}

    _ = await try distributed.dist() // ok
}
