
// This simulates how a library may be providing a default implementation for enqueue in their protocol,
// as e.g. swift-nio does. We'd like to make sure this works as expected since we manually look up conformances
// so the test here is to confirm that.

public struct UnownedJob {}

public protocol SerialExecutor {
  func enqueue(_ job: UnownedJob)
}

public protocol NIOEventLoop: SerialExecutor {}

public extension NIOEventLoop {
  public func enqueue(_ job: UnownedJob) {
    // noop
  }
}