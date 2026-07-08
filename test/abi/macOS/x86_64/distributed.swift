// RUN: %empty-directory(%t)
// RUN: %llvm-nm -g --defined-only -f just-symbols %stdlib_dir/x86_64/libswiftDistributed.dylib > %t/symbols
// RUN: %abi-symbol-checker %s %t/symbols
// RUN: diff -u %S/../../Inputs/macOS/x86_64/distributed/baseline %t/symbols

// REQUIRES: swift_stdlib_no_asserts
// REQUIRES: STDLIB_VARIANT=macosx-x86_64


// *** DO NOT DISABLE OR XFAIL THIS TEST. *** (See comment below.)

// Welcome, Build Wrangler!
//
// This file lists APIs that have recently changed in a way that potentially
// indicates an ABI- or source-breaking problem.
//
// A failure in this test indicates that there is a potential breaking change in
// the Standard Library. If you observe a failure outside of a PR test, please
// reach out to the Standard Library team directly to make sure this gets
// resolved quickly! If your own PR fails in this test, you probably have an
// ABI- or source-breaking change in your commits. Please go and fix it.
//
// Please DO NOT DISABLE THIS TEST. In addition to ignoring the current set of
// ABI breaks, XFAILing this test also silences any future ABI breaks that may
// land on this branch, which simply generates extra work for the next person
// that picks up the mess.
//
// Instead of disabling this test, you'll need to extend the list of expected
// changes at the bottom. (You'll also need to do this if your own PR triggers
// false positives, or if you have special permission to break things.) You can
// find a diff of what needs to be added in the output of the failed test run.
// The order of lines doesn't matter, and you can also include comments to refer
// to any bugs you filed.
//
// Thank you for your help ensuring the stdlib remains compatible with its past!
//                                            -- Your friendly stdlib engineers

// Distributed Symbols

// protocol descriptor for Distributed._DistributedActorStub
Added: _$s11Distributed01_A9ActorStubMp

// base conformance descriptor for Distributed._DistributedActorStub: Distributed.DistributedActor
Added: _$s11Distributed01_A9ActorStubPAA0aB0Tb

// protocol requirements base descriptor for Distributed._DistributedActorStub
Added: _$s11Distributed01_A9ActorStubTL

// Distributed._diagnoseDistributedStubMethodCalled(className: Swift.StaticString, funcName: Swift.StaticString, file: Swift.StaticString, line: Swift.UInt, column: Swift.UInt) -> Swift.Never
Added: _$s11Distributed09_diagnoseA16StubMethodCalled9className04funcG04file4line6columns5NeverOs12StaticStringV_A2KS2utF

// dispatch thunk of Distributed.DistributedActorSystem.remoteCall<A, B, C where A1: Distributed.DistributedActor, B1: Swift.Error, A.ActorID == A1.ID>(on: A1, target: Distributed.RemoteCallTarget, invocation: inout A.InvocationEncoder, throwing: B1.Type, returning: C1.Type) async throws -> C1
Added: _$s11Distributed0A11ActorSystemP10remoteCall2on6target10invocation8throwing9returningqd_1_qd___AA06RemoteE6TargetV17InvocationEncoderQzzqd_0_mqd_1_mtYaKAA0aB0Rd__s5ErrorRd_0_2IDQyd__0bP0Rtzr1_lFTj

// async function pointer to dispatch thunk of Distributed.DistributedActorSystem.remoteCall<A, B, C where A1: Distributed.DistributedActor, B1: Swift.Error, A.ActorID == A1.ID>(on: A1, target: Distributed.RemoteCallTarget, invocation: inout A.InvocationEncoder, throwing: B1.Type, returning: C1.Type) async throws -> C1
Added: _$s11Distributed0A11ActorSystemP10remoteCall2on6target10invocation8throwing9returningqd_1_qd___AA06RemoteE6TargetV17InvocationEncoderQzzqd_0_mqd_1_mtYaKAA0aB0Rd__s5ErrorRd_0_2IDQyd__0bP0Rtzr1_lFTjTu

// method descriptor for Distributed.DistributedActorSystem.remoteCall<A, B, C where A1: Distributed.DistributedActor, B1: Swift.Error, A.ActorID == A1.ID>(on: A1, target: Distributed.RemoteCallTarget, invocation: inout A.InvocationEncoder, throwing: B1.Type, returning: C1.Type) async throws -> C1
Added: _$s11Distributed0A11ActorSystemP10remoteCall2on6target10invocation8throwing9returningqd_1_qd___AA06RemoteE6TargetV17InvocationEncoderQzzqd_0_mqd_1_mtYaKAA0aB0Rd__s5ErrorRd_0_2IDQyd__0bP0Rtzr1_lFTq

// dispatch thunk of Distributed.DistributedActorSystem.remoteCallVoid<A, B where A1: Distributed.DistributedActor, B1: Swift.Error, A.ActorID == A1.ID>(on: A1, target: Distributed.RemoteCallTarget, invocation: inout A.InvocationEncoder, throwing: B1.Type) async throws -> ()
Added: _$s11Distributed0A11ActorSystemP14remoteCallVoid2on6target10invocation8throwingyqd___AA06RemoteE6TargetV17InvocationEncoderQzzqd_0_mtYaKAA0aB0Rd__s5ErrorRd_0_2IDQyd__0bP0Rtzr0_lFTj

// async function pointer to dispatch thunk of Distributed.DistributedActorSystem.remoteCallVoid<A, B where A1: Distributed.DistributedActor, B1: Swift.Error, A.ActorID == A1.ID>(on: A1, target: Distributed.RemoteCallTarget, invocation: inout A.InvocationEncoder, throwing: B1.Type) async throws -> ()
Added: _$s11Distributed0A11ActorSystemP14remoteCallVoid2on6target10invocation8throwingyqd___AA06RemoteE6TargetV17InvocationEncoderQzzqd_0_mtYaKAA0aB0Rd__s5ErrorRd_0_2IDQyd__0bP0Rtzr0_lFTjTu

// method descriptor for Distributed.DistributedActorSystem.remoteCallVoid<A, B where A1: Distributed.DistributedActor, B1: Swift.Error, A.ActorID == A1.ID>(on: A1, target: Distributed.RemoteCallTarget, invocation: inout A.InvocationEncoder, throwing: B1.Type) async throws -> ()
Added: _$s11Distributed0A11ActorSystemP14remoteCallVoid2on6target10invocation8throwingyqd___AA06RemoteE6TargetV17InvocationEncoderQzzqd_0_mtYaKAA0aB0Rd__s5ErrorRd_0_2IDQyd__0bP0Rtzr0_lFTq

// dispatch thunk of Distributed.DistributedTargetInvocationDecoder.decodeNextArgument<A>() throws -> A1
Added: _$s11Distributed0A23TargetInvocationDecoderP18decodeNextArgumentqd__yKlFTj

// method descriptor for Distributed.DistributedTargetInvocationDecoder.decodeNextArgument<A>() throws -> A1
Added: _$s11Distributed0A23TargetInvocationDecoderP18decodeNextArgumentqd__yKlFTq

// dispatch thunk of Distributed.DistributedTargetInvocationEncoder.recordArgument<A>(Distributed.RemoteCallArgument<A1>) throws -> ()
Added: _$s11Distributed0A23TargetInvocationEncoderP14recordArgumentyyAA010RemoteCallF0Vyqd__GKlFTj

// method descriptor for Distributed.DistributedTargetInvocationEncoder.recordArgument<A>(Distributed.RemoteCallArgument<A1>) throws -> ()
Added: _$s11Distributed0A23TargetInvocationEncoderP14recordArgumentyyAA010RemoteCallF0Vyqd__GKlFTq

// dispatch thunk of Distributed.DistributedTargetInvocationEncoder.recordReturnType<A>(A1.Type) throws -> ()
Added: _$s11Distributed0A23TargetInvocationEncoderP16recordReturnTypeyyqd__mKlFTj

// method descriptor for Distributed.DistributedTargetInvocationEncoder.recordReturnType<A>(A1.Type) throws -> ()
Added: _$s11Distributed0A23TargetInvocationEncoderP16recordReturnTypeyyqd__mKlFTq

// dispatch thunk of Distributed.DistributedTargetInvocationResultHandler.onReturn<A>(value: A1) async throws -> ()
Added: _$s11Distributed0A29TargetInvocationResultHandlerP8onReturn5valueyqd___tYaKlFTj

// async function pointer to dispatch thunk of Distributed.DistributedTargetInvocationResultHandler.onReturn<A>(value: A1) async throws -> ()
Added: _$s11Distributed0A29TargetInvocationResultHandlerP8onReturn5valueyqd___tYaKlFTjTu

// method descriptor for Distributed.DistributedTargetInvocationResultHandler.onReturn<A>(value: A1) async throws -> ()
Added: _$s11Distributed0A29TargetInvocationResultHandlerP8onReturn5valueyqd___tYaKlFTq

// (extension in Distributed):Distributed.DistributedActor.asLocalActor.getter : Swift.Actor
Added: _$s11Distributed0A5ActorPAAE07asLocalB0ScA_pvg

// property descriptor for (extension in Distributed):Distributed.DistributedActor.asLocalActor : Swift.Actor
Added: _$s11Distributed0A5ActorPAAE07asLocalB0ScA_pvpMV

// property descriptor for (extension in Distributed):Distributed.DistributedActor.__actorUnownedExecutor : Swift.UnownedSerialExecutor
Added: _$s11Distributed0A5ActorPAAE22__actorUnownedExecutorScevpMV

// Distributed._distributedStubFatalError(function: Swift.String) -> Swift.Never
Added: _$s11Distributed26_distributedStubFatalError8functions5NeverOSS_tF

// Bin compat for typed throws overload of whenLocal
// (extension in Distributed):Distributed.DistributedActor.whenLocal<A, B where A1: Swift.Sendable, B1: Swift.Error>(@Sendable (isolated A) async throws(B1) -> A1) async throws(B1) -> A1?
Added: _$s11Distributed0A5ActorPAAE9whenLocalyqd__Sgqd__xYiYaYbqd_0_YKXEYaqd_0_YKs8SendableRd__s5ErrorRd_0_r0_lF
// async function pointer to (extension in Distributed):Distributed.DistributedActor.whenLocal<A, B where A1: Swift.Sendable, B1: Swift.Error>(@Sendable (isolated A) async throws(B1) -> A1) async throws(B1) -> A1?
Added: _$s11Distributed0A5ActorPAAE9whenLocalyqd__Sgqd__xYiYaYbqd_0_YKXEYaqd_0_YKs8SendableRd__s5ErrorRd_0_r0_lFTu
// ==== @Entitlement / @ValidateRemoteCall distributed call validation ====
// (added by the wip-remote-call-validation branch)

// static Distributed._DistributedValidationKind.validation.getter : Distributed._DistributedValidationKind
Added: _$s11Distributed01_A14ValidationKindV10validationACvgZ
// property descriptor for static Distributed._DistributedValidationKind.validation : Distributed._DistributedValidationKind
Added: _$s11Distributed01_A14ValidationKindV10validationACvpZMV
// Distributed._DistributedValidationKind.init(rawValue: Swift.UInt32) -> Distributed._DistributedValidationKind
Added: _$s11Distributed01_A14ValidationKindV8rawValueACs6UInt32V_tcfC
// Distributed._DistributedValidationKind.rawValue.getter : Swift.UInt32
Added: _$s11Distributed01_A14ValidationKindV8rawValues6UInt32Vvg
// Distributed._DistributedValidationKind.rawValue.modify : Swift.UInt32
Added: _$s11Distributed01_A14ValidationKindV8rawValues6UInt32VvM
// property descriptor for Distributed._DistributedValidationKind.rawValue : Swift.UInt32
Added: _$s11Distributed01_A14ValidationKindV8rawValues6UInt32VvpMV
// Distributed._DistributedValidationKind.rawValue.setter : Swift.UInt32
Added: _$s11Distributed01_A14ValidationKindV8rawValues6UInt32Vvs
// type metadata accessor for Distributed._DistributedValidationKind
Added: _$s11Distributed01_A14ValidationKindVMa
// nominal type descriptor for Distributed._DistributedValidationKind
Added: _$s11Distributed01_A14ValidationKindVMn
// type metadata for Distributed._DistributedValidationKind
Added: _$s11Distributed01_A14ValidationKindVN
// protocol conformance descriptor for Distributed._DistributedValidationKind : Swift.Equatable in Distributed
Added: _$s11Distributed01_A14ValidationKindVSQAAMc
// protocol conformance descriptor for Distributed._DistributedValidationKind : Swift.RawRepresentable in Distributed
Added: _$s11Distributed01_A14ValidationKindVSYAAMc
// static Distributed.DistributedValidation.currentEntitlements.getter : Swift.Set<Swift.String>
Added: _$s11Distributed0A10ValidationO19currentEntitlementsShySSGvgZ
// property descriptor for static Distributed.DistributedValidation.currentEntitlements : Swift.Set<Swift.String>
Added: _$s11Distributed0A10ValidationO19currentEntitlementsShySSGvpZMV
// static Distributed.DistributedValidation.$currentEntitlements.getter : Swift.TaskLocal<Swift.Set<Swift.String>>
Added: _$s11Distributed0A10ValidationO20$currentEntitlementss9TaskLocalCyShySSGGvgZ
// property descriptor for static Distributed.DistributedValidation.$currentEntitlements : Swift.TaskLocal<Swift.Set<Swift.String>>
Added: _$s11Distributed0A10ValidationO20$currentEntitlementss9TaskLocalCyShySSGGvpZMV
// C runtime SPI: first swift5_daval validation record for a distributed target (via the accessible-function record's tagged Flags pointer)
Added: _swift_distributed_getFirstValidationRecord
// static Distributed.DistributedValidation.evaluate(Distributed.EntitlementPolicy) throws -> ()
Added: _$s11Distributed0A10ValidationO8evaluateyyAA17EntitlementPolicyOKFZ
// type metadata accessor for Distributed.DistributedValidation
Added: _$s11Distributed0A10ValidationOMa
// nominal type descriptor for Distributed.DistributedValidation
Added: _$s11Distributed0A10ValidationOMn
// type metadata for Distributed.DistributedValidation
Added: _$s11Distributed0A10ValidationON
// enum case for Distributed.EntitlementPolicy.entitlement(Distributed.EntitlementPolicy.Type) -> (Swift.String) -> Distributed.EntitlementPolicy
Added: _$s11Distributed17EntitlementPolicyO11entitlementyACSScACmFWC
// Distributed.EntitlementPolicy.init(stringLiteral: Swift.String) -> Distributed.EntitlementPolicy
Added: _$s11Distributed17EntitlementPolicyO13stringLiteralACSS_tcfC
// enum case for Distributed.EntitlementPolicy.allOf(Distributed.EntitlementPolicy.Type) -> ([Distributed.EntitlementPolicy]) -> Distributed.EntitlementPolicy
Added: _$s11Distributed17EntitlementPolicyO5allOfyACSayACGcACmFWC
// enum case for Distributed.EntitlementPolicy.anyOf(Distributed.EntitlementPolicy.Type) -> ([Distributed.EntitlementPolicy]) -> Distributed.EntitlementPolicy
Added: _$s11Distributed17EntitlementPolicyO5anyOfyACSayACGcACmFWC
// type metadata accessor for Distributed.EntitlementPolicy
Added: _$s11Distributed17EntitlementPolicyOMa
// nominal type descriptor for Distributed.EntitlementPolicy
Added: _$s11Distributed17EntitlementPolicyOMn
// type metadata for Distributed.EntitlementPolicy
Added: _$s11Distributed17EntitlementPolicyON
// protocol conformance descriptor for Distributed.EntitlementPolicy : Swift.ExpressibleByStringLiteral in Distributed
Added: _$s11Distributed17EntitlementPolicyOs26ExpressibleByStringLiteralAAMc
// protocol conformance descriptor for Distributed.EntitlementPolicy : Swift.ExpressibleByUnicodeScalarLiteral in Distributed
Added: _$s11Distributed17EntitlementPolicyOs33ExpressibleByUnicodeScalarLiteralAAMc
// protocol conformance descriptor for Distributed.EntitlementPolicy : Swift.ExpressibleByExtendedGraphemeClusterLiteral in Distributed
Added: _$s11Distributed17EntitlementPolicyOs43ExpressibleByExtendedGraphemeClusterLiteralAAMc
// Distributed.RemoteCallValidator._check.getter : @Sendable (A.RemoteCallValidationContext) throws(A.RemoteCallValidationFailure) -> ()
Added: _$s11Distributed19RemoteCallValidatorV6_checkyy0bC17ValidationContextQzYb0bcF7FailureQzYKcvg
// property descriptor for Distributed.RemoteCallValidator._check
Added: _$s11Distributed19RemoteCallValidatorV6_checkyy0bC17ValidationContextQzYb0bcF7FailureQzYKcvpMV
// Distributed.RemoteCallValidator.check(context: A.RemoteCallValidationContext) throws(A.RemoteCallValidationFailure) -> ()
Added: _$s11Distributed19RemoteCallValidatorV5check7contexty0bC17ValidationContextQz_t0bcG7FailureQzYKF
// type metadata accessor for Distributed.RemoteCallValidator
Added: _$s11Distributed19RemoteCallValidatorVMa
// nominal type descriptor for Distributed.RemoteCallValidator
Added: _$s11Distributed19RemoteCallValidatorVMn
// Distributed.RemoteCallValidator.init(Distributed.RemoteCallValidator<A>) -> Distributed.RemoteCallValidator<A>
Added: _$s11Distributed19RemoteCallValidatorVyACyxGADcfC
// Distributed.RemoteCallValidator.init(@Sendable (A.RemoteCallValidationContext) throws(A.RemoteCallValidationFailure) -> ()) -> Distributed.RemoteCallValidator<A>
Added: _$s11Distributed19RemoteCallValidatorVyACyxGy0bC17ValidationContextQzYb0bcE7FailureQzYKccfC
// Distributed.EntitlementCheckFailed.description.getter : Swift.String
Added: _$s11Distributed22EntitlementCheckFailedV11descriptionSSvg
// property descriptor for Distributed.EntitlementCheckFailed.description : Swift.String
Added: _$s11Distributed22EntitlementCheckFailedV11descriptionSSvpMV
// Distributed.EntitlementCheckFailed.init(from: Swift.Decoder) throws -> Distributed.EntitlementCheckFailed
Added: _$s11Distributed22EntitlementCheckFailedV4fromACs7Decoder_p_tKcfC
// Distributed.EntitlementCheckFailed.encode(to: Swift.Encoder) throws -> ()
Added: _$s11Distributed22EntitlementCheckFailedV6encode2toys7Encoder_p_tKF
// Distributed.EntitlementCheckFailed.init(missing: Swift.String) -> Distributed.EntitlementCheckFailed
Added: _$s11Distributed22EntitlementCheckFailedV7missingACSS_tcfC
// Distributed.EntitlementCheckFailed.missing.getter : Swift.String
Added: _$s11Distributed22EntitlementCheckFailedV7missingSSvg
// Distributed.EntitlementCheckFailed.missing.modify : Swift.String
Added: _$s11Distributed22EntitlementCheckFailedV7missingSSvM
// property descriptor for Distributed.EntitlementCheckFailed.missing : Swift.String
Added: _$s11Distributed22EntitlementCheckFailedV7missingSSvpMV
// Distributed.EntitlementCheckFailed.missing.setter : Swift.String
Added: _$s11Distributed22EntitlementCheckFailedV7missingSSvs
// type metadata accessor for Distributed.EntitlementCheckFailed
Added: _$s11Distributed22EntitlementCheckFailedVMa
// nominal type descriptor for Distributed.EntitlementCheckFailed
Added: _$s11Distributed22EntitlementCheckFailedVMn
// type metadata for Distributed.EntitlementCheckFailed
Added: _$s11Distributed22EntitlementCheckFailedVN
// protocol conformance descriptor for Distributed.EntitlementCheckFailed : Swift.CustomStringConvertible in Distributed
Added: _$s11Distributed22EntitlementCheckFailedVs23CustomStringConvertibleAAMc
// protocol conformance descriptor for Distributed.EntitlementCheckFailed : Swift.Error in Distributed
Added: _$s11Distributed22EntitlementCheckFailedVs5ErrorAAMc
// protocol conformance descriptor for Distributed.EntitlementCheckFailed : Swift.Decodable in Distributed
Added: _$s11Distributed22EntitlementCheckFailedVSeAAMc
// protocol conformance descriptor for Distributed.EntitlementCheckFailed : Swift.Encodable in Distributed
Added: _$s11Distributed22EntitlementCheckFailedVSEAAMc

// static Distributed.EntitlementPolicy.allOf(Distributed.EntitlementPolicy...) -> Distributed.EntitlementPolicy
Added: _$s11Distributed17EntitlementPolicyO5allOfyA2Cd_tFZ
// static Distributed.EntitlementPolicy.anyOf(Distributed.EntitlementPolicy...) -> Distributed.EntitlementPolicy
Added: _$s11Distributed17EntitlementPolicyO5anyOfyA2Cd_tFZ

// protocol descriptor for Distributed.DistributedRemoteCallValidationMacroIdentifier
Added: _$s11Distributed0A35RemoteCallValidationMacroIdentifierMp
// protocol descriptor for Distributed.DistributedRemoteCallValidationSetting
Added: _$s11Distributed0A27RemoteCallValidationSettingMp
// associated type descriptor for Distributed.DistributedActorSystem.RemoteCallValidation
Added: _$s20RemoteCallValidation11Distributed0D11ActorSystemPTl

// type metadata accessor for Distributed.DistributedRemoteCallValidation
Added: _$s11Distributed0A20RemoteCallValidationOMa
// nominal type descriptor for Distributed.DistributedRemoteCallValidation
Added: _$s11Distributed0A20RemoteCallValidationOMn
// type metadata for Distributed.DistributedRemoteCallValidation
Added: _$s11Distributed0A20RemoteCallValidationON
// associated type descriptor for Distributed.DistributedActorSystem.RemoteCallValidationContext
Added: _$s27RemoteCallValidationContext11Distributed0E11ActorSystemPTl
// associated type descriptor for Distributed.DistributedActorSystem.RemoteCallValidationFailure
Added: _$s27RemoteCallValidationFailure11Distributed0E11ActorSystemPTl
// associated conformance descriptor for Distributed.DistributedActorSystem.RemoteCallValidationFailure: Swift.Error
Added: _$s11Distributed0A11ActorSystemP27RemoteCallValidationFailureAC_s5ErrorTn
// (extension in Distributed):Distributed.DistributedActorSystem.validate(target: Distributed.RemoteCallTarget, context: A.RemoteCallValidationContext) throws(A.RemoteCallValidationFailure) -> Distributed.RemoteCallValidationLookupError?
Added: _$s11Distributed0A11ActorSystemPAAE8validate6target7contextAA31RemoteCallValidationLookupErrorOSgAA0gH6TargetV_0ghI7ContextQzt0ghI7FailureQzYKF

// Distributed.RemoteCallValidationLookupError.description.getter
Added: _$s11Distributed31RemoteCallValidationLookupErrorO11descriptionSSvg
// property descriptor for Distributed.RemoteCallValidationLookupError.description
Added: _$s11Distributed31RemoteCallValidationLookupErrorO11descriptionSSvpMV
// enum case for Distributed.RemoteCallValidationLookupError.actorSystemTypeMismatch(targetIdentifier: Swift.String, requestedSystem: Any.Type)
Added: _$s11Distributed31RemoteCallValidationLookupErrorO23actorSystemTypeMismatchyACSS_ypXptcACmFWC
// type metadata accessor for Distributed.RemoteCallValidationLookupError
Added: _$s11Distributed31RemoteCallValidationLookupErrorOMa
// nominal type descriptor for Distributed.RemoteCallValidationLookupError
Added: _$s11Distributed31RemoteCallValidationLookupErrorOMn
// type metadata for Distributed.RemoteCallValidationLookupError
Added: _$s11Distributed31RemoteCallValidationLookupErrorON
// protocol conformance descriptor for Distributed.RemoteCallValidationLookupError : Swift.Error in Distributed
Added: _$s11Distributed31RemoteCallValidationLookupErrorOs0F0AAMc
// protocol conformance descriptor for Distributed.RemoteCallValidationLookupError : Swift.CustomStringConvertible in Distributed
Added: _$s11Distributed31RemoteCallValidationLookupErrorOs23CustomStringConvertibleAAMc

// type metadata accessor for Distributed.DistributedRemoteCallValidation.InheritMacros
Added: _$s11Distributed0A20RemoteCallValidationO13InheritMacrosVMa
// nominal type descriptor for Distributed.DistributedRemoteCallValidation.InheritMacros
Added: _$s11Distributed0A20RemoteCallValidationO13InheritMacrosVMn
// protocol conformance descriptor for Distributed.DistributedRemoteCallValidation.InheritMacros<Pack{repeat A}> : Distributed.DistributedRemoteCallValidationSetting in Distributed
Added: _$s11Distributed0A20RemoteCallValidationO13InheritMacrosVy_xxQp_QPGAA0abcD7SettingAAMc
// protocol witness table for Distributed.DistributedRemoteCallValidation.InheritMacros<Pack{repeat A}> : Distributed.DistributedRemoteCallValidationSetting in Distributed
Added: _$s11Distributed0A20RemoteCallValidationO13InheritMacrosVy_xxQp_QPGAA0abcD7SettingAAWP

// type metadata accessor for Distributed.EntitlementMacro
Added: _$s11Distributed16EntitlementMacroOMa
// nominal type descriptor for Distributed.EntitlementMacro
Added: _$s11Distributed16EntitlementMacroOMn
// type metadata for Distributed.EntitlementMacro
Added: _$s11Distributed16EntitlementMacroON
// protocol conformance descriptor for Distributed.EntitlementMacro : Distributed.DistributedRemoteCallValidationMacroIdentifier in Distributed
Added: _$s11Distributed16EntitlementMacroOAA0a20RemoteCallValidationC10IdentifierAAMc
// protocol witness table for Distributed.EntitlementMacro : Distributed.DistributedRemoteCallValidationMacroIdentifier in Distributed
Added: _$s11Distributed16EntitlementMacroOAA0a20RemoteCallValidationC10IdentifierAAWP

// type metadata accessor for Distributed.ValidateRemoteCallMacro
Added: _$s11Distributed23ValidateRemoteCallMacroOMa
// nominal type descriptor for Distributed.ValidateRemoteCallMacro
Added: _$s11Distributed23ValidateRemoteCallMacroOMn
// type metadata for Distributed.ValidateRemoteCallMacro
Added: _$s11Distributed23ValidateRemoteCallMacroON
// protocol conformance descriptor for Distributed.ValidateRemoteCallMacro : Distributed.DistributedRemoteCallValidationMacroIdentifier in Distributed
Added: _$s11Distributed23ValidateRemoteCallMacroOAA0acd10ValidationE10IdentifierAAMc
// protocol witness table for Distributed.ValidateRemoteCallMacro : Distributed.DistributedRemoteCallValidationMacroIdentifier in Distributed
Added: _$s11Distributed23ValidateRemoteCallMacroOAA0acd10ValidationE10IdentifierAAWP
