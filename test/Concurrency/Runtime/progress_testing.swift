// RUN: %target-run-simple-swift(-Xfrontend -enable-experimental-concurrency  %import-libdispatch -parse-as-library) | %FileCheck %s --dump-input=always

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: libdispatch

import Dispatch

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

func pprint(_ s: String) {
  fputs("    \(s)    // (at \(#file):\(#line))\n", stderr)
//  print(s)
}

// ==== ------------------------------------------------------------------------

func test() async {
  await TaskLocalProgress.withProgressObserver(totalUnitCount: 10) { progress in
    print("Progress: \(progress.asciiProgressBar)      // details: \(progress)")
  } operation: {
    try! await makeDinner()
  }
}

func makeDinner() async throws -> Meal {
  let progress = await TaskLocalProgress.aggregate(pending: 10)
  print(">> before veggies")
  /*async*/ let veggies = await progress.of(units: 2) {
    await chopVegetables()
  }
  print(">> before meat")
  /*async*/ let meat = await marinateMeat()

  print(">> before oven")
  /*async*/ let oven = await progress.of(units: 6) {
    await preheatOven(temperature: 350)
  }

  print(">> before dinner")
  let dish = Dish(ingredients: await[veggies, meat])
  let dinner = await progress.of(units: 2) {
    await oven.cook(dish)
  }

  print(">> done")
  return dinner
}

func chopVegetables() async -> String {
  await TaskLocalProgress.report(pending: 2) { progress in
    pprint("INCREMENT PROGRESS to 1/2 in \(#function)")
    progress.increment() // 1/2 50%  here; 3/6 = 50% in parent; 3/10 = 30% in top
    pprint("INCREMENT PROGRESS to 2/2 in \(#function)")
    progress.increment() // 2/2 100% here; 6/6 = 100% in parent; 3/10 = 60% in top
    pprint("PROGRESS DONE in \(#function)")
    return "veggies"
  }
}

func marinateMeat() async -> String {
  "meat"
}

func preheatOven(temperature: Int) async -> Oven {
  await TaskLocalProgress.report(pending: 8) { progress in
    for _ in 1...8 {
      progress.increment()
    }
    return .init()
  }
}

struct Dish {
  init(ingredients: [String]) {}
}

struct Meal {}

struct Oven {
  func cook(_ dish: Dish) async -> Meal {
    return .init()
  }
}

// ==== ------------------------------------------------------------------------

func demo2() async {
  await Task.withProgressObserver(totalUnitCount: 10) { progressValue in
    print("Progress: \(progressValue.asciiProgressBar)      // details: \(progressValue)")
  } operation: {
    demo2_observedWork()
  }
}

func demo2_observedWork() async {
  let progress = await TaskLocalProgress.aggregate(pending: 10)

  print("Child 1")
  await progress.of(units: 2) {
    let report = await TaskLocalProgress.report(pending: 6)
    for i in 1...6 {
      pprint("INCREMENT: \(i)/\(6)")
      print("INCREMENT: \(i)/\(6)")
      report.increment()
    } // 6/6 -> 2/2 -> 2/10
  } // end of child 1

  print("Child 2")
  await progress.of(units: 8) {
    let report = await TaskLocalProgress.report(pending: 20)
    for i in 1...20 {
      pprint("INCREMENT: \(i)/\(20)")
      print("INCREMENT: \(i)/\(20)")
      progress.increment()
    } // 6/6 -> 2/2 -> 2/10
  } // end of child 1
}

// ==== ------------------------------------------------------------------------

@main struct Main {
  static func main() async {
    // CHECK: Progress: x
//    _ = try! await test()
    _ = try! await demo2()

  }
}

