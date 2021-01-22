// RUN: %target-run-simple-swift(-Xfrontend -enable-experimental-concurrency  %import-libdispatch -emit-sil)

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: libdispatch

import Dispatch

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

distributed actor class SomeSpecificDistributedActor {
//  // @derived
//  required init(transport: ActorTransport) {
//    self.actorTransport = transport
//    self.actorAddress = ActorAddress(parse: "xxx")
//  }
//  // @derived
//  required init(resolve address: ActorAddress, using transport: ActorTransport) {
//    self.actorAddress = address
//    self.actorTransport = transport
//  }

  distributed func hello() async throws {
    print("hello from \(self.actorAddress)")
  }
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
  func send<Message>(_ message: Message, to recipient: ActorAddress) async throws where Message : Decodable, Message : Encodable {
    fatalError()
  }
  func request<Request, Reply>(replyType: Reply.Type, _ request: Request, from recipient: ActorAddress) async throws where Request : Decodable, Request : Encodable, Reply : Decodable, Reply : Encodable {
    fatalError()
  }
}

// ==== Execute ----------------------------------------------------------------

func run() async {
  let address = ActorAddress(parse: "")
  let x = SomeSpecificDistributedActor(transport: FakeTransport())
  let actor = SomeSpecificDistributedActor(resolve: address, using: FakeTransport())

  print("before")
//  try! await actor.hello() // CHECK: hell
  print("after")
}

runAsyncAndBlock(run)
