// RUN: %target-run-simple-swift(-Xfrontend -enable-experimental-concurrency -Xfrontend -enable-experimental-distributed -parse-as-library) | %FileCheck %s
// REQUIRES: executable_test
// REQUIRES: concurrency
import _Concurrency

distributed actor DA1 {
//  let name = "Charlie"
//  let two: Int
//
//  init(number: Int, transport: ActorTransport) {
//    self.init(transport: transport)
//    self.two = number
//  }

//  distributed func hello() async -> String {
//    return "Hello \(name)"
//  }
}

//distributed actor DA2 {
//  let name: String
//
////  init(transport: ActorTransport) { // FIXME: allow defining such initializer but it must delegate to init(transport:)
////    self.name = "name"
////  }
////  convenience init(name: String, transport: ActorTransport) { // FIXME: allow defining such initializer but it must delegate to init(transport:)
////    self.init(transport: transport)
////    self.name = "nein"
////  }
//  init(name: String, transport: ActorTransport) { // FIXME: allow defining such initializer but it must delegate to init(transport:)
//    self.init(transport: transport)
//    self.name = name
//  }
//
//  // Note that the resolve initializer does leave the `name` uninitialized!
//  // This is *fine* because resolve either returns:
//  // - a different existing instance,
//  // - or creates a proxy, with no storage for the properties allocated
//  //           (except just enough for actorAddress and actorTransport)
//
//  distributed func hello() -> String {
//    "hello!"
//  }
//}

// ==== Fake Transport ---------------------------------------------------------

struct FakeTransport: ActorTransport {
  func resolve<Act>(address: ActorAddress, as actorType: Act.Type)
  throws -> ActorResolved<Act> where Act: DistributedActor {
    print("\(Self.self).resolve(\(address), as: \(Act.self)")
    switch address.uid {
    case 1: return .makeProxy
//    case 2: return .resolved(DA2(name: "DA2", transport: self) as! Act)
    default: fatalError("can't resolve: \(address) as \(Act.self)")
    }
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
let transport = FakeTransport()

func proxy_asserts() {
  // the size must be 88, because this is how much memory we allocate for it in the proxy.
  assert(MemoryLayout<ActorAddress>.size == 88)
}

func test_run() async {
  var address = ActorAddress(parse: "")
  address.path = "da1"
  _ = try! DA1(resolve: address, using: transport)

//  address.path = "da2"
//  _ = try! DA2(resolve: address, using: transport)

  print("after") // CHECK: after
}

@main struct Main {
  static func main() async {
    proxy_asserts()
    await test_run()
  }
}
