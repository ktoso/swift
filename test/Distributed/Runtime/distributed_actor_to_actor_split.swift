// RUN: %empty-directory(%t)
// RUN: split-file %s %t

// RUN: swiftc lib.swift -parse-stdlib -emit-module
// RUN: swiftc use.swift -I . -parse-stdlib

//--- lib.swift
import Swift
import _Concurrency
import Distributed

@_transparent public func f<T: DistributedActor>(_ t: T) -> any Actor {
  return Builtin.distributedActorAsAnyActor(t)
}

//--- use.swift
import Swift
import _Concurrency
import Distributed
import lib

public func g<T: DistributedActor>(_ t: T) {
  _ = f(t)
  _ = Builtin.distributedActorAsAnyActor(t)
}