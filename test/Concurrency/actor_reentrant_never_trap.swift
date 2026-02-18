// RUN: not --crash %target-run-simple-swift(-parse-as-library -Xfrontend -disable-availability-checking) 2>&1 | %FileCheck %s
//
// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: concurrency_runtime

// Test for @reentrant(never) prototype - demonstrates actual trap on reentrancy violation
//
// This test intentionally causes a fatal error to demonstrate that the
// reentrancy checking mechanism is working.

import _Concurrency

// Import the test helper function
@_silgen_name("_swift_actor_setExecutingNonReentrant")
func _setActorExecutingNonReentrant(_ actor: AnyObject, _ value: Bool)

actor ReentrantActor {
  var value: Int = 0
  var helper: HelperActor? = nil

  func setupHelper(_ h: HelperActor) {
    helper = h
  }

  func nonReentrantMethod() async {
    print("nonReentrantMethod: Setting flag")
    // CHECK: nonReentrantMethod: Setting flag

    // Mark this execution as non-reentrant
    _setActorExecutingNonReentrant(self, true)

    print("nonReentrantMethod: Flag set, about to call helper")
    // CHECK: nonReentrantMethod: Flag set, about to call helper

    // Call helper actor, which will try to call back into us
    // This should trap due to reentrancy violation
    if let h = helper {
      await h.callBack(self)
    }

    // This should never be reached
    print("nonReentrantMethod: SHOULD NOT REACH HERE")

    _setActorExecutingNonReentrant(self, false)
  }

  func callback() async {
    print("callback: SHOULD TRAP BEFORE THIS")
    value += 1
  }
}

actor HelperActor {
  func callBack(_ target: ReentrantActor) async {
    print("HelperActor: About to call back into ReentrantActor")
    // CHECK: HelperActor: About to call back into ReentrantActor

    // This should cause a reentrancy trap because ReentrantActor
    // has its isExecutingNonReentrantCode flag set
    await target.callback()

    print("HelperActor: SHOULD NOT REACH HERE")
  }
}

@main
struct Main {
  static func main() async {
    print("Starting reentrancy trap test")
    // CHECK: Starting reentrancy trap test

    let actor = ReentrantActor()
    let helper = HelperActor()
    await actor.setupHelper(helper)

    // This should trap with reentrancy violation
    await actor.nonReentrantMethod()

    // CHECK: Reentrancy violation
    // CHECK: @_reentrant(never)

    print("SHOULD NOT REACH HERE")
  }
}
