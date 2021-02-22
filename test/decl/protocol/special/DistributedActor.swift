// RUN: %target-typecheck-verify-swift -enable-experimental-concurrency
// REQUIRES: concurrency

// Synthesis of distributed actors.

distributed actor D1 {
  var x: Int = 17
}

distributed actor D2 {
  let actorTransport: String // expected-error{{}}
}

// TODO: produce better errors if users attempt to manually write synthesized fields
//distributed actor D3 {
//  let actorTransport: ActorTransport
//}

// ==== Tests ------------------------------------------------------------------

// Make sure the conformances actually happen.
func acceptActor<Act: DistributedActor>(_: Act.Type) { }

func testConformance() {
  acceptActor(D1.self)
}
