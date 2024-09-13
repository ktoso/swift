// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems -disable-availability-checking %S/../Inputs/FakeDistributedActorSystems.swift
// RUN: %target-build-swift -Xllvm -swift-diagnostics-assert-on-error -module-name main -Xfrontend -disable-availability-checking -j2 -parse-as-library -I %t %s %S/../Inputs/FakeDistributedActorSystems.swift -o %t/a.out
// RUN: %target-codesign %t/a.out
// RUN: %target-run %t/a.out | %FileCheck %s --dump-input=always

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: distributed

// rdar://76038845
// UNSUPPORTED: use_os_stdlib
// UNSUPPORTED: back_deployment_runtime

// UNSUPPORTED: OS=windows-msvc

import Distributed
import FakeDistributedActorSystems

typealias DefaultDistributedActorSystem = FakeRoundtripActorSystem

distributed actor Impl: KappaProtocol {
  distributed func get(_ integer: Int, _ string: String) -> String {
    "\(string)-\(integer)"
  }
}

func test() async throws {
  let system = DefaultDistributedActorSystem()

  let local = KappaProtocolImpl(actorSystem: system)
//  let ref = try KappaProtocolImpl.resolve(id: local.id, using: system)

  print("DONE") // CHECK: DONE
}

func test(p: any KappaProtocol) {
  // if remote {
    func doIt<Arg>(opened: Arg) {
      if let cod = opened as? Codable {
        recordArgument(arg: cod)
      }
    }

    _openExistential(p, do: doIt)
  // }
}

func recordArgument<Arg: Codable>(arg: Arg) {
  print("OK: \(arg)")
}

@main struct Main {
  static func main() async {
    let impl = KappaProtocolImpl(actorSystem: .init())
    try! await test(p: impl)
  }
}
