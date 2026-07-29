// RUN: %target-swift-emit-silgen %s -target %target-swift-5.7-abi-triple | %FileCheck %s
// RUN: %target-swift-emit-silgen %s -target %target-swift-5.7-abi-triple | %FileCheck %s --check-prefix=NOAVAIL

// REQUIRES: concurrency
// REQUIRES: distributed
// REQUIRES: OS=macosx

// The distributed thunk emits tracing calls on its remote branch: an interval
// around encoding the invocation, and an event right before 'remoteCall'.
//
// The tracing entry points are '@_alwaysEmitIntoClient' and do their own
// '#available' check for the tracing runtime, so the thunk calls them
// unconditionally and no availability check is emitted into the thunk itself.
// NOAVAIL-NOT: _stdlib_isOSVersionAtLeast

import Distributed

distributed actor DA {
  typealias ActorSystem = LocalTestingDistributedActorSystem

  // CHECK-LABEL: sil hidden [thunk] [distributed] {{.*}} @$s25distributed_thunk_tracing2DAC5greet4nameS2S_tYaKFTE

  // The thunk only takes the remote branch when the actor is remote
  // CHECK: function_ref @swift_distributed_actor_is_remote

  // The encoding interval begins before the first 'record...' call...
  // CHECK: function_ref @$s11Distributed06_traceA20EncodeArgumentsBegin11targetActor0F10Identifier13argumentCounts6UInt64Vx_SSSitAA0aG0RzlF
  // CHECK: function_ref @$s11Distributed29LocalTestingInvocationEncoderV14recordArgumentyyAA010RemoteCallG0VyxGKSeRzSERzlF

  // ...and ends right after 'doneRecording'
  // CHECK: function_ref @$s11Distributed29LocalTestingInvocationEncoderV13doneRecordingyyKF
  // CHECK: function_ref @$s11Distributed06_traceA18EncodeArgumentsEnd_7successys6UInt64V_SbtF

  // The outbound event carries the mangled accessor record name of the target
  // CHECK: string_literal utf8 "$s25distributed_thunk_tracing2DAC5greet4nameS2S_tYaKFTE"
  // CHECK: function_ref @$s11Distributed06_traceA10RemoteCall11targetActor0E10Identifieryx_SStAA0aF0RzlF
  // CHECK: apply {{.*}}<DA>

  // ...and only then is 'remoteCall' invoked
  // CHECK: function_ref {{.*}}remoteCall

  // If one of the 'record...' calls throws, a 'catch' closes the encoding
  // interval with 'success: false' and then rethrows
  // CHECK: function_ref @$s11Distributed06_traceA18EncodeArgumentsEnd_7successys6UInt64V_SbtF
  // CHECK: throw
  distributed func greet(name: String) -> String {
    return "Hello, \(name)!"
  }
}
