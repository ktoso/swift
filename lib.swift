import Swift
import _Concurrency
import Distributed

@_transparent public func f<T: DistributedActor>(_ t: T) -> any Actor {
  return Builtin.distributedActorAsAnyActor(t)
}

// swiftc lib.swift -parse-stdlib -emit-module
// swiftc use.swift -I . -parse-stdlib