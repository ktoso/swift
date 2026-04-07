// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems -target %target-swift-5.7-abi-triple %S/../Inputs/FakeDistributedActorSystems.swift
// RUN: %target-build-swift -module-name main -target %target-swift-5.7-abi-triple -j2 -parse-as-library -enable-experimental-feature DistributedActorLocalKeyword -Xfrontend -disable-experimental-parser-round-trip -I %t %s %S/../Inputs/FakeDistributedActorSystems.swift -o %t/a.out
// RUN: %target-codesign %t/a.out
// RUN: %target-run %t/a.out | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: distributed
// REQUIRES: swift_feature_DistributedActorLocalKeyword

// rdar://76038845
// UNSUPPORTED: use_os_stdlib
// UNSUPPORTED: back_deployment_runtime

// FIXME(distributed): Distributed actors currently have some issues on windows, isRemote always returns false. rdar://82593574
// UNSUPPORTED: OS=windows-msvc

import Distributed

distributed actor Capybara {
  let name: String = "Caplin"

  // Only the local capybara can do this!
  func eat() -> String {
    "watermelon"
  }

  distributed func greet() -> String {
    "hello"
  }
}

typealias DefaultDistributedActorSystem = FakeActorSystem

// ==== -----------------------------------------------------------------------
// MARK: distributed(local) parameter — call distributed func without try

func callDistributedOnLocal(da: distributed(local) Capybara) async -> String {
  // distributed(local) means known-local: distributed func calls don't need try
  await da.greet()
}

func callLocalOnlyOnLocal(da: distributed(local) Capybara) async -> String {
  // distributed(local) means known-local: non-distributed func calls are allowed
  await da.eat()
}

func getNameOnLocal(da: distributed(local) Capybara) async -> String {
  // distributed(local) means known-local: property access is allowed
  await da.name
}

// ==== -----------------------------------------------------------------------
// MARK: Tests

func test() async throws {
  let system = DefaultDistributedActorSystem()

  let local = Capybara(actorSystem: system)

  // Test: distributed(local) parameter — call distributed func
  let greetResult = await callDistributedOnLocal(da: local)
  // CHECK: greetResult: hello
  print("greetResult: \(greetResult)")

  // Test: distributed(local) parameter — call non-distributed func
  let eatResult = await callLocalOnlyOnLocal(da: local)
  // CHECK: eatResult: watermelon
  print("eatResult: \(eatResult)")

  // Test: distributed(local) parameter — access stored property
  let nameResult = await getNameOnLocal(da: local)
  // CHECK: nameResult: Caplin
  print("nameResult: \(nameResult)")
}

@main struct Main {
  static func main() async {
    try! await test()
  }
}
