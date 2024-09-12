// RUN: %empty-directory(%t)
// RUN: %target-swift-frontend-emit-module -emit-module-path %t/FakeDistributedActorSystems.swiftmodule -module-name FakeDistributedActorSystems -disable-availability-checking %S/../Inputs/FakeDistributedActorSystems.swift -plugin-path %swift-plugin-dir
// RUN: %target-build-swift -module-name main -Xfrontend -dump-macro-expansions -Xfrontend -disable-availability-checking -j2 -parse-as-library -I %t %s %S/../Inputs/FakeDistributedActorSystems.swift -plugin-path %swift-plugin-dir -o %t/a.out
// RUN: %target-codesign %t/a.out
// RUN: %target-run %t/a.out | %FileCheck %s --color --dump-input=always

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: distributed

// rdar://76038845
// UNSUPPORTED: use_os_stdlib
// UNSUPPORTED: back_deployment_runtime

// FIXME(distributed): Distributed actors currently have some issues on windows, isRemote always returns false. rdar://82593574
// UNSUPPORTED: OS=windows-msvc

import Distributed
import FakeDistributedActorSystems

// API package ----

@Resolvable
protocol Alpha: Codable, DistributedActor
  where ActorSystem: DistributedActorSystem<any Codable>,
        ActorSystem.ActorID: Codable {
//  distributed func take(alpha: some Alpha) async throws

  // distributed func getAlpha() async throws -> some Alpha
  // ->
  associatedtype R_getAlpha: Alpha
  distributed func getAlpha() async throws -> R_getAlpha

//  distributed func boop()
}

// "Server" package ----

distributed actor AlphaImpl: Alpha {
  typealias ActorSystem = FakeRoundtripActorSystem

  distributed func take(alpha: some Alpha) async throws {
//    try await alpha.boop()
  }

  distributed func getAlpha() async throws -> AlphaImpl {
    print("IMPL: getAlpha, return \(self)")
    return self
  }

  distributed func boop() {
    print("Boop: \(self.id)")
  }
}

// ==== ------------------------------------------------------------------------

@main struct Main {
  static func main() async throws {
    let serverSystem = FakeRoundtripActorSystem()
    let clientSystem = FakeRemoteCallActorSystem(remoteSystem: serverSystem)

    // "server"
    let serverImpl = AlphaImpl(actorSystem: serverSystem)
    try await serverImpl.take(alpha: serverImpl)

    // "client"
    let clientRef: some Alpha = try $Alpha.resolve(id: serverImpl.id, using: clientSystem)
    // try await clientRef.take(alpha: serverImpl)
    let sa: some Alpha = try await clientRef.getAlpha()
    print("sa = \(sa), type = \(type(of: sa))")

    print("DONE")
    // CHECK: DONE
  }
}


