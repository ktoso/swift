// RUN: %target-run-simple-swift(-Xfrontend -enable-experimental-concurrency -Xfrontend -enable-experimental-distributed -parse-as-library -Xfrontend -debug-cycles) | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: concurrency

import _Concurrency

distributed actor Person {
  var name: String = ""

  // typealias LocalStorage = ...

  // compiler can synthesize this
  static func mapStorage<T>(keyPath: AnyKeyPath) -> KeyPath<LocalStorage, T> {
    switch keyPath {
//    case \Person.name:
//      return \DistributedActorLocalStorage.name as! KeyPath<DistributedActorLocalStorage, T>
    default:
      fatalError("Bad key path: \(keyPath)")
    }
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
}

// ==== Execute ----------------------------------------------------------------
let address = ActorAddress(parse: "")
let transport = FakeTransport()

func test_run() async {
  print("before") // CHECK: before

  let p = try! Person(resolve: address, using: transport)
  _ = p

  print("after") // CHECK: after
}

@main struct Main {
  static func main() async {
    await test_run()
  }
}
