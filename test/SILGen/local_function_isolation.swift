// RUN: %target-swift-emit-silgen-ossa -o /dev/null -enable-sil-opaque-values %s
// RUN: %target-swift-frontend -Xllvm -sil-print-types -emit-silgen %s -target %target-swift-5.1-abi-triple | %FileCheck %s
// RUN: %target-swift-frontend -Xllvm -sil-print-types -emit-silgen %s -target %target-swift-5.1-abi-triple -enable-upcoming-feature NonisolatedNonsendingByDefault | %FileCheck %s --check-prefix=CHECK-NONSENDING
// RUN: %target-swift-frontend -Xllvm -sil-print-types -emit-silgen %s -target %target-swift-5.1-abi-triple | %FileCheck %s --check-prefix=CHECK-NESTED

// REQUIRES: concurrency
// REQUIRES: swift_feature_NonisolatedNonsendingByDefault

class NotSendable {}

func callee(_ ns: NotSendable) {}

actor MyActor {
  func isolatedToSelf(ns: NotSendable) {
    // CHECK-LABEL: sil private [ossa] @$s24local_function_isolation7MyActorC14isolatedToSelf2nsyAA11NotSendableC_tF08implicitH7CaptureL_yyYaF : $@convention(thin) @async (@guaranteed NotSendable, @sil_isolated @guaranteed MyActor) -> () {
    func implicitSelfCapture() async {

      // CHECK: [[COPY:%.*]] = copy_value %1 : $MyActor
      // CHECK-NEXT: [[BORROW:%.*]] = begin_borrow [[COPY]] : $MyActor
      // CHECK-NEXT: hop_to_executor [[BORROW]] : $MyActor

      // CHECK: [[FN:%.*]] = function_ref @$s24local_function_isolation4testyyYaF : $@convention(thin) @async () -> ()
      // CHECK-NEXT: apply [[FN]]() : $@convention(thin) @async () -> ()
      await test()

      // CHECK: hop_to_executor [[BORROW]] : $MyActor
      // CHECK: [[FN:%.*]] = function_ref @$s24local_function_isolation6calleeyyAA11NotSendableCF : $@convention(thin) (@guaranteed NotSendable) -> ()
      // CHECK-NEXT: apply [[FN]](%0) : $@convention(thin) (@guaranteed NotSendable) -> ()

      // we need to hop back to 'self' here
      callee(ns)

      // CHECK: end_borrow [[BORROW]] : $MyActor
      // CHECK-NEXT: destroy_value [[COPY]] : $MyActor
    }
  }
}

func f(isolation: isolated MyActor, ns: NotSendable) {
  // CHECK-LABEL: sil private [ossa] @$s24local_function_isolation1f0C02nsyAA7MyActorCYi_AA11NotSendableCtF23implicitIsolatedCaptureL_yyYaF : $@convention(thin) @async (@guaranteed NotSendable, @sil_isolated @guaranteed MyActor) -> () {
  func implicitIsolatedCapture() async {

    // CHECK: [[COPY:%.*]] = copy_value %1 : $MyActor
    // CHECK-NEXT: [[BORROW:%.*]] = begin_borrow [[COPY]] : $MyActor
    // CHECK-NEXT: hop_to_executor [[BORROW]] : $MyActor

    // CHECK: [[FN:%.*]] = function_ref @$s24local_function_isolation4testyyYaF : $@convention(thin) @async () -> ()
    // CHECK-NEXT: apply [[FN]]() : $@convention(thin) @async () -> ()
    await test()

    // we need to hop back to 'isolation' here
    callee(ns)

    // CHECK: end_borrow [[BORROW]] : $MyActor
    // CHECK-NEXT: destroy_value [[COPY]] : $MyActor
  }
}

func test() async {}

// A generic actor type, which causes the generic self parameter
// (actor isolation parameter) to be added to captures of the
// local/nested function.
actor GenericActor<K> {
  var i: Int = 0
  func outerFunc() async {
    func accessSelf() async -> Int {
      // CHECK-LABEL: sil private [ossa] @$s24local_function_isolation12GenericActorC9outerFuncyyYaF10accessSelfL_SiyYalF : $@convention(thin) @async <K> (@sil_isolated @guaranteed GenericActor<K>) -> Int {
      return 0
    }
    await print(accessSelf())
  }
}

// Make sure defer doesn't capture anything.
actor DeferInsideInitActor {
  init(foo: ()) async throws {
    // CHECK-LABEL: sil private [ossa] @$s24local_function_isolation20DeferInsideInitActorC3fooACyt_tYaKcfc6$deferL_yyF : $@convention(thin) () -> () {
    defer {}
    self.init()
  }
}

// Make sure defer inside a Task closure in an init inherits the closure's isolation.
actor DeferInsideTaskInitActor {
  init(foo: ()) async throws {
    Task {
      self.assertIsolated("Inside task")
      // CHECK-LABEL: // $defer #1 () in closure #1 in DeferInsideTaskInitActor.init(foo:)
      // CHECK-NEXT: // Isolation: actor_instance. name: 'self'
      // CHECK-NEXT: sil private [ossa] @$s24local_function_isolation24DeferInsideTaskInitActorC3fooACyt_tYaKcfcyyYacfU_6$deferL_yyF : $@convention(thin) () -> () {
      defer {}
      print("noop")
    }
    self.init()
  }
}

// https://github.com/swiftlang/swift/issues/93432
// An async defer in a global actor isolated closure must hop to the actor on
// entry, not to the global executor
@MainActor
final class AsyncDeferInGlobalActorClosure {
  func run() {
    Task {
      MainActor.assertIsolated("Inside task")
      // CHECK-LABEL: // $defer #1 () in closure #1 in AsyncDeferInGlobalActorClosure.run()
      // CHECK-NEXT: // Isolation: nonisolated(nonsending)
      // CHECK-NEXT: sil private [ossa] @$s24local_function_isolation30AsyncDeferInGlobalActorClosureC3runyyFyyYacfU_6$deferL_yyYaF : $@convention(thin) @caller_isolated @async (@sil_isolated @sil_implicit_leading_param @guaranteed Builtin.ImplicitActor) -> () {
      // CHECK-NEXT: // %0
      // CHECK-NEXT: bb0(%0 : @guaranteed $Builtin.ImplicitActor):

      // We must not randomly hop off:
      // CHECK-NOT: #Optional.none!enumelt

      // The defer is caller-isolated and hops to the isolation it is passed:
      // CHECK-NEXT: hop_to_executor %0 : $Builtin.ImplicitActor
      // CHECK: } // end sil function '$s24local_function_isolation30AsyncDeferInGlobalActorClosureC3runyyFyyYacfU_6$deferL_yyYaF'
      defer {
        MainActor.assertIsolated("Inside task")
        await test()
      }
      await test()
    }
  }
}


actor NestedAsyncInSyncActor {
  public func outer() async {
    // CHECK-LABEL: sil private [ossa] @$s24local_function_isolation22NestedAsyncInSyncActorC5outeryyYaF6middleL_yyF : $@convention(thin) (@sil_isolated @guaranteed NestedAsyncInSyncActor) -> () {
    func middle() {
      // CHECK-LABEL: sil private [ossa] @$s24local_function_isolation22NestedAsyncInSyncActorC5outeryyYaF6middleL_yyF5innerL_yyYaF : $@convention(thin) @async (@sil_isolated @guaranteed NestedAsyncInSyncActor) -> () {
      func inner() async {}
      _ = inner
    }
    _ = middle
  }
}

// CHECK-LABEL: sil hidden [ossa] @$s24local_function_isolation13outerFunctionyyScA_pYaF : $@convention(thin) @async (@guaranteed any Actor) -> () {
func outerFunction(_ a: any Actor) async {
  // CHECK-LABEL: sil private [ossa] @$s24local_function_isolation13outerFunctionyyScA_pYaF06middleE0L_yyScA_pYaF : $@convention(thin) @async (@guaranteed any Actor) -> () {
  func middleFunction(_ isolated: any Actor) async {
    // CHECK-LABEL: sil private [ossa] @$s24local_function_isolation13outerFunctionyyScA_pYaF06middleE0L_yyScA_pYaF05innerE0L_yyYaF : $@convention(thin) @async () -> () {
    func innerFunction() async {}
  }

  await middleFunction(a)
}

// Check async defer matches enclosing isolation
actor AsyncDeferActor {
  func foo() async {
    // CHECK-LABEL: // $defer #1 () in AsyncDeferActor.foo()
    // CHECK-NEXT: // Isolation: nonisolated(nonsending)
    // CHECK-NEXT: sil private [ossa] @$s24local_function_isolation15AsyncDeferActorC3fooyyYaF6$deferL_yyYaF : $@convention(thin) @caller_isolated @async (@sil_isolated @sil_implicit_leading_param @guaranteed Builtin.ImplicitActor, @guaranteed AsyncDeferActor) -> () {
    // CHECK-NEXT: // %0
    // CHECK-NEXT: // %1 "self"
    // CHECK-NEXT: bb0(%0 : @guaranteed $Builtin.ImplicitActor, %1 : @closureCapture @guaranteed $AsyncDeferActor):
    defer {
      await test()
    }

    await test()
  }
}


// An async defer in a closure isolated to an actor instance is passed the
// isolation of the closure and hops to it on entry.
actor AsyncDeferInActorInstanceClosure {
  func run() {
    Task {
      self.assertIsolated("Inside task")
      // CHECK-LABEL: // $defer #1 () in closure #1 in AsyncDeferInActorInstanceClosure.run()
      // CHECK-NEXT: // Isolation: nonisolated(nonsending)
      // CHECK-NEXT: sil private [ossa] @$s24local_function_isolation32AsyncDeferInActorInstanceClosureC3runyyFyyYacfU_6$deferL_yyYaF : $@convention(thin) @caller_isolated @async (@sil_isolated @sil_implicit_leading_param @guaranteed Builtin.ImplicitActor) -> () {
      // CHECK-NEXT: // %0
      // CHECK-NEXT: bb0(%0 : @guaranteed $Builtin.ImplicitActor):
      // CHECK-NEXT: hop_to_executor %0 : $Builtin.ImplicitActor
      // CHECK-NEXT: // function_ref test()
      // CHECK-NEXT: %2 = function_ref @$s24local_function_isolation4testyyYaF : $@convention(thin) @async () -> ()
      // CHECK-NEXT: %3 = apply %2() : $@convention(thin) @async () -> ()
      // CHECK-NEXT: hop_to_executor %0 : $Builtin.ImplicitActor
      // CHECK-NEXT: %5 = tuple ()
      // CHECK-NEXT: return %5 : $()
      // CHECK-NEXT: } // end sil function '$s24local_function_isolation32AsyncDeferInActorInstanceClosureC3runyyFyyYacfU_6$deferL_yyYaF'
      defer {
        await test()
      }
      await test()
    }
  }
}

// The same for a closure that is isolated to a captured 'isolated' parameter.
func asyncDeferInCapturedIsolatedParamClosure(isolated: isolated any Actor) async {
  let _: () async -> Void = {
    isolated.assertIsolated("Inside closure")
    // CHECK-LABEL: // $defer #1 () in closure #1 in asyncDeferInCapturedIsolatedParamClosure(isolated:)
    // CHECK-NEXT: // Isolation: nonisolated(nonsending)
    // CHECK-NEXT: sil private [ossa] @$s24local_function_isolation40asyncDeferInCapturedIsolatedParamClosure8isolatedyScA_pYi_tYaFyyYacfU_6$deferL_yyYaF : $@convention(thin) @caller_isolated @async (@sil_isolated @sil_implicit_leading_param @guaranteed Builtin.ImplicitActor) -> () {
    // CHECK-NEXT: // %0
    // CHECK-NEXT: bb0(%0 : @guaranteed $Builtin.ImplicitActor):
    // CHECK-NEXT: hop_to_executor %0 : $Builtin.ImplicitActor
    // CHECK-NEXT: // function_ref test()
    // CHECK-NEXT: %2 = function_ref @$s24local_function_isolation4testyyYaF : $@convention(thin) @async () -> ()
    // CHECK-NEXT: %3 = apply %2() : $@convention(thin) @async () -> ()
    // CHECK-NEXT: hop_to_executor %0 : $Builtin.ImplicitActor
    // CHECK-NEXT: %5 = tuple ()
    // CHECK-NEXT: return %5 : $()
    // CHECK-NEXT: } // end sil function '$s24local_function_isolation40asyncDeferInCapturedIsolatedParamClosure8isolatedyScA_pYi_tYaFyyYacfU_6$deferL_yyYaF'
    defer {
      await test()
    }
    await test()
  }
}

// Nested async defers in a closure isolated to a global actor.
@MainActor
final class NestedAsyncDeferInGlobalActorClosure {
  func run() {
    // CHECK-LABEL: // $defer #1 () in closure #1 in NestedAsyncDeferInGlobalActorClosure.run()
    // CHECK-NEXT: // Isolation: nonisolated(nonsending)
    // CHECK-NEXT: sil private [ossa] @$s24local_function_isolation36NestedAsyncDeferInGlobalActorClosureC3runyyFyyYacfU_6$deferL_yyYaF : $@convention(thin) @caller_isolated @async (@sil_isolated @sil_implicit_leading_param @guaranteed Builtin.ImplicitActor) -> () {
    // CHECK-NEXT: // %0
    // CHECK-NEXT: bb0(%0 : @guaranteed $Builtin.ImplicitActor):
    // CHECK-NESTED-LABEL: // $defer #1 () in $defer #1 () in closure #1 in NestedAsyncDeferInGlobalActorClosure.run()
    // CHECK-NESTED-NEXT: // Isolation: nonisolated(nonsending)
    // CHECK-NESTED-NEXT: sil private [ossa] @$s24local_function_isolation36NestedAsyncDeferInGlobalActorClosureC3runyyFyyYacfU_6$deferL_yyYaFAEL_yyYaF : $@convention(thin) @caller_isolated @async (@sil_isolated @sil_implicit_leading_param @guaranteed Builtin.ImplicitActor) -> () {
    // CHECK-NESTED-NEXT: // %0
    // CHECK-NESTED-NEXT: bb0(%0 : @guaranteed $Builtin.ImplicitActor):
    Task {
      defer {
        defer {
          await test()
        }
        await test()
      }
      await test()
    }
  }
}

// Nested async defers in a closure isolated to an actor instance.
actor NestedAsyncDeferInActorInstanceClosure {
  func run() {
    // CHECK-LABEL: // $defer #1 () in closure #1 in NestedAsyncDeferInActorInstanceClosure.run()
    // CHECK-NEXT: // Isolation: nonisolated(nonsending)
    // CHECK-NEXT: sil private [ossa] @$s24local_function_isolation38NestedAsyncDeferInActorInstanceClosureC3runyyFyyYacfU_6$deferL_yyYaF : $@convention(thin) @caller_isolated @async (@sil_isolated @sil_implicit_leading_param @guaranteed Builtin.ImplicitActor) -> () {
    // CHECK-NEXT: // %0
    // CHECK-NEXT: bb0(%0 : @guaranteed $Builtin.ImplicitActor):
    // CHECK-NEXT: hop_to_executor %0 : $Builtin.ImplicitActor
    // CHECK-NESTED-LABEL: // $defer #1 () in $defer #1 () in closure #1 in NestedAsyncDeferInActorInstanceClosure.run()
    // CHECK-NESTED-NEXT: // Isolation: nonisolated(nonsending)
    // CHECK-NESTED-NEXT: sil private [ossa] @$s24local_function_isolation38NestedAsyncDeferInActorInstanceClosureC3runyyFyyYacfU_6$deferL_yyYaFAEL_yyYaF : $@convention(thin) @caller_isolated @async (@sil_isolated @sil_implicit_leading_param @guaranteed Builtin.ImplicitActor) -> () {
    // CHECK-NESTED-NEXT: // %0
    // CHECK-NESTED-NEXT: bb0(%0 : @guaranteed $Builtin.ImplicitActor):
    // CHECK-NESTED-NEXT: hop_to_executor %0 : $Builtin.ImplicitActor
    Task {
      self.assertIsolated("Inside task")
      defer {
        defer {
          await test()
        }
        await test()
      }
      await test()
    }
  }
}

// A sync defer that does not use the isolation does not capture the actor
actor PlainSyncDeferInActorInstanceClosure {
  func run() {
    // CHECK-LABEL: // $defer #1 () in closure #1 in PlainSyncDeferInActorInstanceClosure.run()
    // CHECK-NEXT: // Isolation: actor_instance. name: 'self'
    // CHECK-NEXT: sil private [ossa] @$s24local_function_isolation36PlainSyncDeferInActorInstanceClosureC3runyyFyyYacfU_6$deferL_yyF : $@convention(thin) () -> () {
    // CHECK-NEXT: bb0:
    Task {
      self.assertIsolated("Inside task")
      defer {
        print("done")
      }
      await test()
    }
  }
}

// https://github.com/swiftlang/swift/issues/93432
// rdar://190427405
// An 'async let' initializer never inherits the isolation of its parent, in any
// mode - an async defer in a closure in it is passed the closure's isolation,
// which is none
@MainActor
final class AsyncDeferInAsyncLet {
  func run() async {
    // CHECK-LABEL: // implicit closure #1 in AsyncDeferInAsyncLet.run()
    // CHECK-NEXT: // Isolation: @concurrent
    // CHECK-NEXT: sil private [ossa] @$s24local_function_isolation012AsyncDeferInD3LetC3runyyYaFSiyYaYbcfu_ : $@convention(thin) @Sendable @async @substituted <τ_0_0> () -> (@out τ_0_0, @error any Error) for <Int> {
    // CHECK-LABEL: // closure #1 in implicit closure #1 in AsyncDeferInAsyncLet.run()
    // CHECK-NEXT: // Isolation: @concurrent
    // CHECK-NEXT: sil private [ossa] @$s24local_function_isolation012AsyncDeferInD3LetC3runyyYaFSiyYaYbcfu_SiyYaXEfU_ : $@convention(thin) @async () -> Int {
    // CHECK-LABEL: // $defer #1 () in closure #1 in implicit closure #1 in AsyncDeferInAsyncLet.run()
    // CHECK-NEXT: // Isolation: nonisolated(nonsending)
    // CHECK-NEXT: sil private [ossa] @$s24local_function_isolation012AsyncDeferInD3LetC3runyyYaFSiyYaYbcfu_SiyYaXEfU_6$deferL_yyYaF : $@convention(thin) @caller_isolated @async (@sil_isolated @sil_implicit_leading_param @guaranteed Builtin.ImplicitActor) -> () {
    // CHECK-NEXT: // %0
    // CHECK-NEXT: bb0(%0 : @guaranteed $Builtin.ImplicitActor):
    // CHECK-NEXT: hop_to_executor %0 : $Builtin.ImplicitActor
    // CHECK-NEXT: // function_ref test()
    // CHECK-NEXT: %2 = function_ref @$s24local_function_isolation4testyyYaF : $@convention(thin) @async () -> ()
    // CHECK-NEXT: %3 = apply %2() : $@convention(thin) @async () -> ()
    // CHECK-NEXT: hop_to_executor %0 : $Builtin.ImplicitActor
    // CHECK-NEXT: %5 = tuple ()
    // CHECK-NEXT: return %5 : $()
    // CHECK-NEXT: } // end sil function '$s24local_function_isolation012AsyncDeferInD3LetC3runyyYaFSiyYaYbcfu_SiyYaXEfU_6$deferL_yyYaF'
    // CHECK-NONSENDING-LABEL: // implicit closure #1 in AsyncDeferInAsyncLet.run()
    // CHECK-NONSENDING-NEXT: // Isolation: @concurrent
    // CHECK-NONSENDING-NEXT: sil private [ossa] @$s24local_function_isolation012AsyncDeferInD3LetC3runyyYaFSiyYaYbcfu_ : $@convention(thin) @Sendable @async @substituted <τ_0_0> () -> (@out τ_0_0, @error any Error) for <Int> {
    // CHECK-NONSENDING-LABEL: // closure #1 in implicit closure #1 in AsyncDeferInAsyncLet.run()
    // CHECK-NONSENDING-NEXT: // Isolation: @concurrent
    // CHECK-NONSENDING-NEXT: sil private [ossa] @$s24local_function_isolation012AsyncDeferInD3LetC3runyyYaFSiyYaYbcfu_SiyYaXEfU_ : $@convention(thin) @async () -> Int {
    // CHECK-NONSENDING-LABEL: // $defer #1 () in closure #1 in implicit closure #1 in AsyncDeferInAsyncLet.run()
    // CHECK-NONSENDING-NEXT: // Isolation: nonisolated(nonsending)
    // CHECK-NONSENDING-NEXT: sil private [ossa] @$s24local_function_isolation012AsyncDeferInD3LetC3runyyYaFSiyYaYbcfu_SiyYaXEfU_6$deferL_yyYaF : $@convention(thin) @caller_isolated @async (@sil_isolated @sil_implicit_leading_param @guaranteed Builtin.ImplicitActor) -> () {
    // CHECK-NONSENDING-NEXT: // %0
    // CHECK-NONSENDING-NEXT: bb0(%0 : @guaranteed $Builtin.ImplicitActor):
    // CHECK-NONSENDING-NEXT: hop_to_executor %0 : $Builtin.ImplicitActor
    // CHECK-NONSENDING-NEXT: // function_ref test()
    // CHECK-NONSENDING-NEXT: %2 = function_ref @$s24local_function_isolation4testyyYaF : $@convention(thin) @caller_isolated @async (@sil_isolated @sil_implicit_leading_param @guaranteed Builtin.ImplicitActor) -> ()
    // CHECK-NONSENDING-NEXT: %3 = apply %2(%0) : $@convention(thin) @caller_isolated @async (@sil_isolated @sil_implicit_leading_param @guaranteed Builtin.ImplicitActor) -> ()
    // CHECK-NONSENDING-NEXT: hop_to_executor %0 : $Builtin.ImplicitActor
    // CHECK-NONSENDING-NEXT: %5 = tuple ()
    // CHECK-NONSENDING-NEXT: return %5 : $()
    // CHECK-NONSENDING-NEXT: } // end sil function '$s24local_function_isolation012AsyncDeferInD3LetC3runyyYaFSiyYaYbcfu_SiyYaXEfU_6$deferL_yyYaF'
    async let result: Int = {
      defer {
        await test()
      }
      await test()
      return 42
    }()
    _ = await result
  }
}

func testAsyncDeferIsolatedParam(isolated: isolated (any Actor)? = nil) async {
  let x: Int = 0

  // CHECK-LABEL: // $defer #1 () in testAsyncDeferIsolatedParam(isolated:)
  // CHECK-NEXT: // Isolation: nonisolated(nonsending)
  // CHECK-NEXT: sil private [ossa] @$s24local_function_isolation27testAsyncDeferIsolatedParam8isolatedyScA_pSgYi_tYaF6$deferL_yyYaF : $@convention(thin) @caller_isolated @async (@sil_isolated @sil_implicit_leading_param @guaranteed Builtin.ImplicitActor, Int, @guaranteed Optional<any Actor>) -> () {
  // CHECK-NEXT: // %0
  // CHECK-NEXT: // %1 "x"
  // CHECK-NEXT: // %2 "isolated"
  // CHECK-NEXT: bb0(%0 : @guaranteed $Builtin.ImplicitActor, %1 : @closureCapture $Int, %2 : @closureCapture @guaranteed $Optional<any Actor>):
  defer {
    await test()
    _ = x
  }

  _ = x


  let _: @MainActor () async -> Void = {
    let z: Int = 0

    // CHECK-LABEL: // $defer #1 () in closure #1 in testAsyncDeferIsolatedParam(isolated:)
    // CHECK-NEXT: // Isolation: nonisolated(nonsending)
    // CHECK-NEXT: sil private [ossa] @$s24local_function_isolation27testAsyncDeferIsolatedParam8isolatedyScA_pSgYi_tYaFyyYaScMYccfU_6$deferL_yyYaF : $@convention(thin) @caller_isolated @async (@sil_isolated @sil_implicit_leading_param @guaranteed Builtin.ImplicitActor, Int) -> () {
    // CHECK-NEXT: // %0
    // CHECK-NEXT: // %1 "z"
    // CHECK-NEXT: bb0(%0 : @guaranteed $Builtin.ImplicitActor, %1 : @closureCapture $Int):
    defer {
      await test()
      _ = z
    }

    _ = z

    func inner(isolated: isolated (any Actor)? = nil) async {
      let y: Int = 0
      // CHECK-LABEL: // $defer #1 () in inner #1 (isolated:) in closure #1 in testAsyncDeferIsolatedParam(isolated:)
      // CHECK-NEXT: // Isolation: nonisolated(nonsending)
      // CHECK-NEXT: sil private [ossa] @$s24local_function_isolation27testAsyncDeferIsolatedParam8isolatedyScA_pSgYi_tYaFyyYaScMYccfU_5innerL_ACyADYi_tYaF6$deferL_yyYaF : $@convention(thin) @caller_isolated @async (@sil_isolated @sil_implicit_leading_param @guaranteed Builtin.ImplicitActor, @guaranteed Optional<any Actor>, Int) -> () {
      // CHECK-NEXT: // %0
      // CHECK-NEXT: // %1 "isolated"
      // CHECK-NEXT: // %2 "y"
      // CHECK-NEXT: bb0(%0 : @guaranteed $Builtin.ImplicitActor, %1 : @closureCapture @guaranteed $Optional<any Actor>, %2 : @closureCapture $Int):
      defer {
        await test()

        // CHECK-LABEL: // $defer #1 () in $defer #1 () in inner #1 (isolated:) in closure #1 in testAsyncDeferIsolatedParam(isolated:)
        // CHECK-NEXT: // Isolation: nonisolated(nonsending)
        // CHECK-NEXT: sil private [ossa] @$s24local_function_isolation27testAsyncDeferIsolatedParam8isolatedyScA_pSgYi_tYaFyyYaScMYccfU_5innerL_ACyADYi_tYaF6$deferL_yyYaFAFL_yyYaF : $@convention(thin) @caller_isolated @async (@sil_isolated @sil_implicit_leading_param @guaranteed Builtin.ImplicitActor, @guaranteed Optional<any Actor>) -> () {
        // CHECK-NEXT: // %0
        // CHECK-NEXT: // %1 "isolated"
        // CHECK-NEXT: bb0(%0 : @guaranteed $Builtin.ImplicitActor, %1 : @closureCapture @guaranteed $Optional<any Actor>):
        defer {
          await test()
        }
        _ = y
      }

      _ = y
    }
  }
}
