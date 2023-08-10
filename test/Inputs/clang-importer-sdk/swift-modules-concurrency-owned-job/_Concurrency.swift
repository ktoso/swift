public struct ExecutorJob {}

public protocol SerialExecutor {
  // pretend old SDK with `__owned` param rather than ``
  func enqueue(_ job: __owned ExecutorJob)
}