import Swift
import _Concurrency
import Distributed
import lib

public func g<T: DistributedActor>(_ t: T) {
  _ = f(t)
  _ = Builtin.distributedActorAsAnyActor(t)
}