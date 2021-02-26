// RUN: %target-run-simple-swift(-Xfrontend -enable-experimental-concurrency -parse-as-library) | %FileCheck %s

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
//    self.actorTransport = transport
//    self.actorAddress = transport.assignAddress(Self.self)
//  }
//  // @derived
//  required init(resolve address: ActorAddress, using transport: ActorTransport) {
//    self.actorAddress = address
//    self.actorTransport = transport
//  }

//  distributed func hello() async throws {
//    // print("hello from \(self.actorAddress)")
//  }
}

// ==== Fake Transport ---------------------------------------------------------

struct FakeTransport: ActorTransport {
  func resolve<Act>(address: ActorAddress, as actorType: Act.Type)
    throws -> ResolvedDistributedActor<Act> where Act: DistributedActor {
    fatalError("resolve is not implemented yet.")
  }

  func assignAddress<Act>(
    _ actorType: Act.Type
//    ,
//    onActorCreated: (Act) -> ()
  ) -> ActorAddress where Act : DistributedActor {
    let mock = ActorAddress.random
    return mock
  }
}

struct ResolveAsSpecificTransport: ActorTransport {
  func resolve<Act>(address: ActorAddress, as actorType: Act.Type)
    throws -> ResolvedDistributedActor<Act> where Act: DistributedActor {
    fatalError("resolve is not implemented yet.")
  }
  func assignAddress<Act>(
    _ actorType: Act.Type
  ) -> ActorAddress where Act : DistributedActor {
    fatalError()
  }
}

// ==== Execute ----------------------------------------------------------------
let address = ActorAddress(parse: "")
let transport = FakeTransport()

func test_init_local() {
  let local = SomeSpecificDistributedActor(transport: transport)
  print("local.actorAddress: \(local.actorAddress)")

}
func test_init_resolve() {
  let remote = try! SomeSpecificDistributedActor(resolve: address, using: transport)
  print(remote)
}

func test_address() {
  let actor = SomeSpecificDistributedActor(transport: transport)
  _ = actor.actorAddress
}

func test_run() async {
  print("before") // CHECK: before
//  try! await actor.hello()
  print("after") // CHECK: after
}

@main struct Main {
  static func main() async {
    test_init_local()

    test_init_resolve()
    await test_run()

    // CHECK: fail
  }
}
