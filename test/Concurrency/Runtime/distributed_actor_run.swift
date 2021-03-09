// RUN: %target-run-simple-swift(-Xfrontend -enable-experimental-concurrency -Xfrontend -enable-experimental-distributed -parse-as-library) | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: concurrency

import _Concurrency

//protocol DA {
//  var address: ActorAddress { get }
//
//}
//
//class MANUAL: DA {
//  // @derived
//  let address: ActorAddress
//
//  init( actorAddress: ActorAddress) {
//    self.address = actorAddress
//  }
//}


distributed actor SomeSpecificDistributedActor {
//  // @derived let actorTransport: ActorTransport
//  // @derived let actorAddress: ActorAddress

//  // @derived
//  required init(transport: ActorTransport) {
//    self.$transport = transport
//    self.$address = ActorAddress(parse: "xxx")
//  }
//  // @derived
//  required init(resolve address: ActorAddress, using transport: ActorTransport) {
//    self.$address = address
//    self.$transport = transport
//  }

//  distributed func hello() async throws {
//    // print("hello from \(self.$address)")
//  }
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
  _ = SomeSpecificDistributedActor(transport: transport)
  _ = try! SomeSpecificDistributedActor(resolve: address, using: transport)
}

func test_address() {
  let actor = SomeSpecificDistributedActor(transport: transport)
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
