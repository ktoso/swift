// RUN: %target-run-simple-swift(-Xfrontend -enable-experimental-concurrency %import-libdispatch -parse-as-library) | %FileCheck %s

// REQUIRES: concurrency
// REQUIRES: executable_test

// UNSUPPORTED: OS=windows-msvc
// UNSUPPORTED: back_deployment_runtime

actor Simple {
  var count = 0
  func report() {
    print("simple.count == \(count)")
    count += 1
  }
}

actor Custom {
  var count = 0
  nonisolated let simple = Simple()

  @available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
  nonisolated var unownedExecutor: UnownedSerialExecutor {
    print("custom unownedExecutor")
    return simple.unownedExecutor
  }

  func report() async {
    print("custom.count == \(count)")
    count += 1

    await simple.report()
  }
}

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
@main struct Main {
  static func main() async {
    print("begin")
    let actor = Custom()
    await actor.report()
    await actor.report()
    await actor.report()
    print("end")
  }
}

// CHECK:      begin
// CHECK-NEXT: custom unownedExecutor
// CHECK-NEXT: custom.count == 0
// CHECK-NEXT: simple.count == 0
// CHECK-NEXT: custom unownedExecutor
// CHECK-NEXT: custom.count == 1
// CHECK-NEXT: simple.count == 1
// CHECK-NEXT: custom unownedExecutor
// CHECK-NEXT: custom.count == 2
// CHECK-NEXT: simple.count == 2
// CHECK-NEXT: end
