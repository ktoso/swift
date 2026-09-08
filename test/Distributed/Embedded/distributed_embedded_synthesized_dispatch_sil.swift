// RUN: %target-swift-frontend -emit-sil -enable-experimental-feature Embedded -enable-experimental-feature EmbeddedDistributed -parse-as-library -wmo -target %target-cpu-apple-macos14 %s %S/Runtime/Inputs/EmbeddedFakeActorSystem.swift | %FileCheck %s

// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// Verify the compiler synthesizes `_executeDistributedTarget(target:invocationDecoder:resultHandler:)`
// on every embedded distributed actor. Each actor's synthesized method
// dispatches over its own set of distributed funcs.

import _Concurrency
import Distributed

typealias DefaultDistributedActorSystem = EmbeddedFakeRoundtripActorSystem

distributed actor Greeter {
  distributed func hello(name: String) -> String {
    return "Hello, \(name)!"
  }
  distributed func square(_ x: Int) -> Int {
    return x * x
  }
  distributed func notify(_ message: String) {
    _ = message
  }
}

// Force the synthesized `_executeDistributedTarget` to be emitted; in
// real programs the actor system's `remoteCall` calls it. Without a
// call site, dead-code elimination would drop it.
@main struct Main {
  static func main() async {
    let system = EmbeddedFakeRoundtripActorSystem()
    let greeter = Greeter(actorSystem: system)
    var decoder = EmbeddedFakeInvocationDecoder(buffer: CallBuffer())
    let handler = EmbeddedFakeResultHandler(buffer: ResultBuffer())
    let target = RemoteCallTarget("not-a-real-target")
    do {
      try await greeter._executeDistributedTarget(
          target: target,
          invocationDecoder: &decoder,
          resultHandler: handler)
    } catch {}
  }
}

// `_executeDistributedTarget` is synthesized on the actor.
// CHECK-LABEL: sil{{.*}} @${{.+}}GreeterC25_executeDistributedTarget6target17invocationDecoder13resultHandler

// The synthesized body references the single generic decode / onReturn
// members, specialized for each distributed func's concrete types (`SS_Tg5`
// for String, `Si_Tg5` for Int) - not per-type overloads.
// CHECK-DAG: function_ref @${{.+}}EmbeddedFakeInvocationDecoderV18decodeNextArgument{{.+}}SerializationRequirement{{.+}}SS_Tg5
// CHECK-DAG: function_ref @${{.+}}EmbeddedFakeInvocationDecoderV18decodeNextArgument{{.+}}SerializationRequirement{{.+}}Si_Tg5
// CHECK-DAG: function_ref @${{.+}}EmbeddedFakeResultHandlerV8onReturn{{.+}}SerializationRequirement{{.+}}SS_Tg5
// CHECK-DAG: function_ref @${{.+}}EmbeddedFakeResultHandlerV8onReturn{{.+}}SerializationRequirement{{.+}}Si_Tg5
// CHECK-DAG: function_ref @${{.+}}EmbeddedFakeResultHandlerV12onReturnVoidyyYaKF

// And references each distributed func's distributed thunk (TE), which
// in turn handles the isRemote check and the local-vs-remote dispatch.
// CHECK-DAG: function_ref @${{.+}}GreeterC5hello4nameS2S_tYaKFTE
// CHECK-DAG: function_ref @${{.+}}GreeterC6squareyS2iYaKFTE
// CHECK-DAG: function_ref @${{.+}}GreeterC6notifyyySSYaKFTE
