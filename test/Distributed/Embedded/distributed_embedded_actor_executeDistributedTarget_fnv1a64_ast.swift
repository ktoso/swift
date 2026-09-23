// RUN: %target-swift-frontend -dump-ast -enable-experimental-feature Embedded -enable-experimental-feature EmbeddedDistributed -parse-as-library -wmo -target %target-cpu-apple-macos14 -module-name main -distributed-id-gen=fnv1a-64 %s %S/Runtime/Inputs/EmbeddedFakeActorSystem.swift 2>&1 | %FileCheck %s

// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded
// REQUIRES: swift_feature_EmbeddedDistributed
// REQUIRES: optimized_stdlib

// Pseudo code of the synthesized func under '-distributed-id-gen=fnv1a-64':
//
//   nonisolated func _executeDistributedTarget(
//     target: RemoteCallTarget,
//     invocationDecoder: inout ActorSystem.InvocationDecoder,
//     resultHandler: ActorSystem.ResultHandler
//   ) async throws {
//     switch target.numericIdentifier { // an FNV-1a 64 hash, folded at compile time
//     case .some(<hash of "4main7GreeterC5hello4nameS2S_tYaKFTE">):
//       let arg0: String = try invocationDecoder.decodeNextArgument()
//       let result = try await self.hello(name: arg0)
//       try await resultHandler.onReturn(result)
//       return
//     default:
//       throw EmbeddedDistributedTargetNotFound(numericTarget: target.numericIdentifier)
//     }
//   }
//
// This is the numeric-identifier counterpart of
// distributed_embedded_actor_executeDistributedTarget_ast.swift: the length
// bucketing and the 'identifierEquals' byte-compare are gone, replaced by a flat
// switch on the numeric identifier.

import _Concurrency
import Distributed

typealias DefaultDistributedActorSystem = EmbeddedFakeRoundtripActorSystem

distributed actor Greeter {
  distributed func hello(name: String) -> String {
    return "Hello, \(name)!"
  }
}

// The synthesized dispatch method.
// CHECK: func_decl {{.*}}"_executeDistributedTarget(target:invocationDecoder:resultHandler:)"

// It switches on the numeric identifier, not the byte count.
// CHECK: switch_stmt
// CHECK: member_ref_expr {{.*}}decl="Distributed.(file).RemoteCallTarget.numericIdentifier

// Hash stability (wire contract): the identifier is the FNV-1a 64 hash of the
// mangled thunk name "4main7GreeterC5hello4nameS2S_tYaKFTE" (the "$e"/"$s"
// mangling-flavor prefix is stripped before hashing, so standard-Swift and
// Embedded peers agree on this exact value). If this number changes, the wire
// format changed -- do not "fix" the test, understand why.
// CHECK: pattern_optional_some
// CHECK: integer_literal_expr {{.*}}value="2651054949897273157"

// The matched branch: decode the argument, call the local impl, deliver the result.
// CHECK: decl="{{.*}}EmbeddedFakeInvocationDecoder extension.decodeNextArgument{{.*}}Argument -> String)]"
// CHECK: decl="{{.*}}Greeter.hello(name:)
// CHECK: decl="{{.*}}EmbeddedFakeResultHandler extension.onReturn{{.*}}Success -> String)]"

// The numeric dispatch never touches the name-based matching machinery.
// CHECK-NOT: RemoteCallTarget.identifierEquals
// CHECK-NOT: RemoteCallTarget.identifierByteCount
// CHECK-NOT: decl="Swift.(file).String.UTF8View
