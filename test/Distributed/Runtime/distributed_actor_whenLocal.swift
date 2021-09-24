// RUN: %target-run-simple-swift( -Xfrontend -disable-availability-checking -Xfrontend -enable-experimental-distributed -parse-as-library) | %FileCheck %s --dump-input=always

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: distributed

// rdar://76038845
// XXXX_UNSUPPORTED: use_os_stdlib
// XXXX_UNSUPPORTED: back_deployment_runtime

import _Distributed

distributed actor Capybara {
  // only the local capybara can do this!
  func eat() -> String {
    "watermelon"
  }
}


// ==== Fake Transport ---------------------------------------------------------

@available(SwiftStdlib 5.5, *)
struct ActorAddress: ActorIdentity {
  let address: String
  init(parse address: String) {
    self.address = address
  }
}

@available(SwiftStdlib 5.5, *)
struct FakeTransport: ActorTransport {
  func decodeIdentity(from decoder: Decoder) throws -> AnyActorIdentity {
    fatalError("not implemented:\(#function)")
  }

  func resolve<Act>(_ identity: AnyActorIdentity, as actorType: Act.Type)
  throws -> Act? where Act: DistributedActor {
    return nil
  }

  func assignIdentity<Act>(_ actorType: Act.Type) -> AnyActorIdentity
      where Act: DistributedActor {
    let id = ActorAddress(parse: "xxx")
    return .init(id)
  }

  func actorReady<Act>(_ actor: Act) where Act: DistributedActor {
  }

  func resignIdentity(_ id: AnyActorIdentity) {
  }
}

func test() async throws {
  let transport = FakeTransport()


  let local = Capybara(transport: transport)
  await local.eat() // SHOULD ERROR
  let valueWhenLocal: String? = await local.whenLocal { guaranteedToBeLocal in
    guaranteedToBeLocal.eat()
  }

//  let remote = try Capybara.resolve(local.id, using: transport)
//  let valueWhenRemote: String? = await remote.whenLocal { guaranteedToBeLocal in
//    await guaranteedToBeLocal.eat()
//  }

  // CHECK: valueWhenLocal: watermelon
  print("valueWhenLocal: \(valueWhenLocal ?? "nil")")

//  // CHECK: valueWhenRemote: nil
//  print("valueWhenRemote: \(valueWhenRemote ?? "nil")")
}

@available(SwiftStdlib 5.5, *)
@main struct Main {
  static func main() async {
    try! await test()
  }
}

