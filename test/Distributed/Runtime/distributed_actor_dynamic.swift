// RUN: %target-run-simple-swift(-Xfrontend -enable-experimental-distributed -parse-as-library) | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: distributed

// UNSUPPORTED: use_os_stdlib
// UNSUPPORTED: back_deployment_runtime

import _Distributed

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
distributed actor LocalWorker {
  distributed func function() async throws -> String {
    ""
  }
}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
extension LocalWorker {
  @_dynamicReplacement(for: _remote_function)
  func _cluster_remote_function() async throws -> String {
    "Replaced"
  }
}

// ==== Fake Transport ---------------------------------------------------------

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
struct FakeTransport: ActorTransport {
  func resolve<Act>(address: ActorAddress, as actorType: Act.Type)
    throws -> ActorResolved<Act> where Act: DistributedActor {
    fatalError()
  }

  func assignAddress<Act>(
    _ actorType: Act.Type
  ) -> ActorAddress where Act : DistributedActor {
    let address = ActorAddress(parse: "xxx")
    print("assign type:\(actorType), address:\(address)")
    return address
  }

  public func actorReady<Act>(
    _ actor: Act
  ) where Act: DistributedActor {
    print("ready actor:\(actor), address:\(actor.actorAddress)")
  }

  public func resignAddress(
    _ address: ActorAddress
  ) {
    print("ready address:\(address)")
  }
}

// ==== Execute ----------------------------------------------------------------

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
func test() async throws {
  let address = ActorAddress(parse: "")
  let transport = FakeTransport()

  let worker = try! LocalWorker(resolve: address, using: transport)
//  let worker = LocalWorker()
//  let x = try await worker._remote_function()
  let x = try await worker.function()
  print("call: \(x)")
  // CHECK: assign type:LocalWorker, address:[[ADDRESS:.*]]
  // CHECK: ready actor:main.LocalWorker, address:[[ADDRESS]]
  // CHECK: Replaced
}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@main struct Main {
  static func main() async {
    try! await test()
  }
}
