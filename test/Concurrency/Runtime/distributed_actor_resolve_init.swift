// RUN: %target-run-simple-swift(-Xfrontend -enable-experimental-concurrency -Xfrontend -enable-experimental-distributed -parse-as-library) | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: concurrency

import _Concurrency

distributed actor DA {
  let name = "name"
}

// ==== Fake Transport ---------------------------------------------------------

struct FakeTransport: ActorTransport {
  func resolve<Act>(address: ActorAddress, as actorType: Act.Type)
    throws -> ActorResolved<Act> where Act: DistributedActor {
    fatalError()
  }
  func assignAddress<Act>(
    _ actorType: Act.Type
//    ,
//    onActorCreated: (Act) -> ()
  ) -> ActorAddress where Act : DistributedActor {
    fatalError()
  }
}

// ==== Execute ----------------------------------------------------------------
let address = ActorAddress(parse: "")
let transport = FakeTransport()

func test_initializers() {
  _ = DA(transport: transport)
  _ = try! DA(resolve: address, using: transport)
}

func test_address() {
  let actor = DA(transport: transport)
  _ = actor.$address
}

func test_run() async {
  print("before") // CHECK: before
//  try! await actor.hello()
  print("after") // CHECK: after
}

@main struct Main {
  static func main() async {
    await test_run()
  }
}
