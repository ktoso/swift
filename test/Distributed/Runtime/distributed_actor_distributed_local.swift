// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems -target %target-swift-5.7-abi-triple %S/../Inputs/FakeDistributedActorSystems.swift
// RUN: %target-build-swift -module-name main -target %target-swift-5.7-abi-triple -j2 -parse-as-library -enable-experimental-feature DistributedActorLocalKeyword -I %t %s %S/../Inputs/FakeDistributedActorSystems.swift -o %t/a.out
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

  distributed func echo(_ message: String) -> String {
    message
  }
}

typealias DefaultDistributedActorSystem = FakeActorSystem

// ==== -----------------------------------------------------------------------
// MARK: distributed(local) parameter — concrete type

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
// MARK: distributed(local) parameter — generic type

func callOnGenericLocal<T: DistributedActor>(
  da: distributed(local) T
) async -> String {
  "\(da.id)"
}

// ==== -----------------------------------------------------------------------
// MARK: distributed(local) with isolated

func callIsolatedLocal(da: isolated distributed(local) Capybara) -> String {
  // isolated + distributed(local): synchronous access, no try needed
  da.eat()
}

// ==== -----------------------------------------------------------------------
// MARK: distributed(local) in closure parameter

func useClosureWithLocal(da: Capybara) async -> String {
  let fn: (distributed(local) Capybara) async -> String = { localDA in
    await localDA.greet()
  }
  return await fn(da)
}

// ==== -----------------------------------------------------------------------
// MARK: distributed(local) with optional

func callOptionalLocal(da: distributed(local) Capybara?) async throws -> String {
  guard let da else { return "nil" }
  return try await da.greet()
}

// ==== -----------------------------------------------------------------------
// MARK: distributed(local) return type

func makeLocalCapybara(system: FakeActorSystem) -> distributed(local) Capybara {
  Capybara(actorSystem: system)
}

// ==== -----------------------------------------------------------------------
// MARK: Init-returns-local — constructor creates a known-local actor

func callOnInitLocal(system: FakeActorSystem) async -> String {
  let da = Capybara(actorSystem: system)
  // 'da' is implicitly known-local because it was just constructed
  return await da.greet()
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

  // Test: distributed(local) with generic parameter
  let genericResult = await callOnGenericLocal(da: local)
  // CHECK: genericResult:
  print("genericResult: \(genericResult)")

  // Test: isolated distributed(local) — synchronous access
  let isolatedResult = await callIsolatedLocal(da: local)
  // CHECK: isolatedResult: watermelon
  print("isolatedResult: \(isolatedResult)")

  // Test: distributed(local) in closure
  let closureResult = await useClosureWithLocal(da: local)
  // CHECK: closureResult: hello
  print("closureResult: \(closureResult)")

  // Test: distributed(local) optional — non-nil
  let optionalResult = try await callOptionalLocal(da: local)
  // CHECK: optionalResult: hello
  print("optionalResult: \(optionalResult)")

  // Test: distributed(local) optional — nil
  let nilResult = try await callOptionalLocal(da: nil)
  // CHECK: nilResult: nil
  print("nilResult: \(nilResult)")

  // Test: distributed(local) return type
  let returned = makeLocalCapybara(system: system)
  let returnedGreet = try await returned.greet()
  // CHECK: returnedGreet: hello
  print("returnedGreet: \(returnedGreet)")

  // Test: init-returns-local
  let initLocalResult = await callOnInitLocal(system: system)
  // CHECK: initLocalResult: hello
  print("initLocalResult: \(initLocalResult)")
}

@main struct Main {
  static func main() async {
    try! await test()
  }
}
