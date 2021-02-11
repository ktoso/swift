// RUN: %target-run-simple-swift(-Xfrontend -enable-experimental-concurrency  %import-libdispatch) | %FileCheck %s

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: libdispatch

import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

class StringLike: CustomStringConvertible {
  let value: String
  init(_ value: String) {
    self.value = value
  }

  var description: String { value }
}

func printTaskLocal<Key>(
  _ key: KeyPath<TaskLocalValues, Key>,
  _ expected: Key.Value? = nil,
  file: String = #file, line: UInt = #line
) async where Key: TaskLocalKey {
  let value = await Task.local(key)
  print("\(Key.self): \(value) at \(file):\(line)")
  if let expected = expected {
    assert("\(expected)" == "\(value)",
      "Expected [\(expected)] but found: \(value), at \(file):\(line)")
  }
}

extension TaskLocalValues {

  struct StringKey: TaskLocalKey {
    static var defaultValue: String { .init("<undefined>") }
    static var inherit: TaskLocalInheritance { .never }
  }
  var string: StringKey { .init() }

}

// ==== ------------------------------------------------------------------------

func test_async_let() async {
  // CHECK: StringKey: <undefined> {{.*}}
  await printTaskLocal(\.string)
  await Task.withLocal(\.string, boundTo: "top") {
    // CHECK: StringKey: top {{.*}}
    await printTaskLocal(\.string)

    // CHECK: StringKey: <undefined> {{.*}}
    async let child = printTaskLocal(\.string)
    await child

    // CHECK: StringKey: top {{.*}}
    await printTaskLocal(\.string)
  }
}

// FIXME: unlock once https://github.com/apple/swift/pull/35874 is merged
//func test_async_group() async {
//  // COM: CHECK: test_async_group
//  print(#function)
//
//  // COM: CHECK: StringKey: <undefined> {{.*}}
//  await printTaskLocal(\.string)
//  await Task.withLocal(\.string, boundTo: "top") {
//    // COM: CHECK: StringKey: top {{.*}}
//    await printTaskLocal(\.string)
//
//    try! await Task.withGroup(resultType: String.self) { group -> Void in
//      // COM: CHECK: StringKey: top {{.*}}
//      await printTaskLocal(\.string)
//    }
//  }
//}

runAsyncAndBlock(test_async_let)
//runAsyncAndBlock(test_async_group)
