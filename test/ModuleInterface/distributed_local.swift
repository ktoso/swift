// RUN: %empty-directory(%t)
// RUN: split-file %s %t

// RUN: %target-swift-frontend -emit-module -module-name Library \
// RUN:     -swift-version 6 -enable-library-evolution \
// RUN:     -enable-experimental-feature DistributedActorLocalKeyword \
// RUN:     -disable-availability-checking \
// RUN:     -o %t/Library.swiftmodule \
// RUN:     -emit-module-interface-path %t/Library.swiftinterface \
// RUN:     %t/Library.swift

/// Verify the interface contains distributed(local)
// RUN: %FileCheck %s < %t/Library.swiftinterface

/// Verify that we can build from Library.swiftmodule
// RUN: %target-swift-frontend -typecheck -module-name Client \
// RUN:     -swift-version 6 \
// RUN:     -enable-experimental-feature DistributedActorLocalKeyword \
// RUN:     -disable-availability-checking \
// RUN:     %t/Client.swift -I%t

/// Verify that we can build from swiftinterface when swiftmodule was deleted
// RUN: rm %t/Library.swiftmodule
// RUN: %target-swift-frontend -typecheck -module-name Client \
// RUN:     -swift-version 6 \
// RUN:     -enable-experimental-feature DistributedActorLocalKeyword \
// RUN:     -disable-availability-checking \
// RUN:     %t/Client.swift -I%t

// REQUIRES: concurrency
// REQUIRES: distributed

//--- Library.swift

import Distributed

public distributed actor MyDA {
  public typealias ActorSystem = LocalTestingDistributedActorSystem

  public func localOnly() -> String { "local" }
  public distributed func remoteCallable() -> String { "remote" }
}

// CHECK: public func acceptLocal(da: distributed(local) Library::MyDA)
public func acceptLocal(da: distributed(local) MyDA) {}

// CHECK: public func acceptLocalGeneric<T>(t: distributed(local) T) where T : Distributed::DistributedActor
public func acceptLocalGeneric<T: DistributedActor>(t: distributed(local) T) {}

//--- Client.swift

import Library
import Distributed

func test(da: distributed(local) MyDA) async {
  _ = da.remoteCallable()
  da.localOnly()
}
