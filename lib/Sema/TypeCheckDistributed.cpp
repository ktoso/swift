//===--- TypeCheckDistributed.cpp - Distributed ---------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2021 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
//
// This file implements type checking support for Swift's concurrency model.
//
//===----------------------------------------------------------------------===//
#include "TypeCheckConcurrency.h"
#include "TypeCheckDistributed.h"
#include "TypeCheckMacros.h"
#include "TypeChecker.h"
#include "swift/Strings.h"
#include "swift/AST/ASTWalker.h"
#include "swift/AST/ArgumentList.h"
#include "swift/AST/ConformanceLookup.h"
#include "swift/AST/Initializer.h"
#include "swift/AST/ParameterList.h"
#include "swift/AST/ProtocolConformance.h"
#include "swift/AST/DistributedDecl.h"
#include "swift/AST/NameLookupRequests.h"
#include "swift/AST/TypeCheckRequests.h"
#include "swift/AST/TypeVisitor.h"
#include "swift/AST/ImportCache.h"
#include "swift/AST/ExistentialLayout.h"
#include "swift/Basic/Assertions.h"
#include "swift/Basic/Defer.h"
#include "swift/AST/ASTPrinter.h"
#include "swift/AST/Decl.h"
#include "swift/AST/SourceFile.h"
#include "swift/Basic/SourceManager.h"
#include "swift/Parse/Parser.h"
#include "llvm/Support/MemoryBuffer.h"

using namespace swift;

// ==== ------------------------------------------------------------------------

bool swift::ensureDistributedModuleLoaded(const ValueDecl *decl) {
  auto &C = decl->getASTContext();
  auto moduleAvailable = evaluateOrDefault(
      C.evaluator, DistributedModuleIsAvailableRequest{decl}, false);
  return moduleAvailable;
}

bool
DistributedModuleIsAvailableRequest::evaluate(Evaluator &evaluator,
                                              const ValueDecl *decl) const {
  auto &C = decl->getASTContext();

  auto DistributedModule = C.getLoadedModule(C.Id_Distributed);
  if (!DistributedModule) {
    decl->diagnose(diag::distributed_decl_needs_explicit_distributed_import,
                   decl)
        .fixItAddImport("Distributed");
    return false;
  }

  auto &importCache = C.getImportCache();
  if (importCache.isImportedBy(DistributedModule, decl->getDeclContext())) {
    return true;
  }

  // seems we're missing the Distributed module, ask to import it explicitly
  decl->diagnose(diag::distributed_decl_needs_explicit_distributed_import,
                 decl);
  return false;
}

/******************************************************************************/
/************ LOCATING AD-HOC PROTOCOL REQUIREMENT IMPLS **********************/
/******************************************************************************/

static AbstractFunctionDecl *findDistributedAdHocRequirement(
    NominalTypeDecl *decl, Identifier identifier,
    std::function<bool(AbstractFunctionDecl *)> matchFn) {
  auto &C = decl->getASTContext();

  // It would be nice to check if this is a DistributedActorSystem
  // "conforming" type, but we can't do this as we invoke this function WHILE
  // deciding if the type conforms or not;

  // Not via `ensureDistributedModuleLoaded` to avoid generating a warning,
  // we won't be emitting the offending decl after all.
  if (!C.getLoadedModule(C.Id_Distributed)) {
    return nullptr;
  }

  llvm::SmallVector<ValueDecl *, 2> results;
  decl->lookupQualified(decl, DeclNameRef(identifier),
                        SourceLoc(), NLFlags::QualifiedDefault, results);
  for (auto value : results) {
    auto func = dyn_cast<AbstractFunctionDecl>(value);
    if (func && matchFn(func))
      return func;
  }

  return nullptr;
}

AbstractFunctionDecl *
GetDistributedActorSystemRemoteCallFunctionRequest::evaluate(
    Evaluator &evaluator, NominalTypeDecl *decl, bool isVoidReturn) const {
  auto &C = decl->getASTContext();
  auto callId = isVoidReturn ? C.Id_remoteCallVoid : C.Id_remoteCall;

  return findDistributedAdHocRequirement(
      decl, callId, [isVoidReturn](AbstractFunctionDecl *func) {
        return func->isDistributedActorSystemRemoteCall(isVoidReturn);
      });
}

AbstractFunctionDecl *
GetDistributedTargetInvocationEncoderRecordArgumentFunctionRequest::evaluate(
    Evaluator &evaluator, NominalTypeDecl *decl) const {
  auto &C = decl->getASTContext();

  return findDistributedAdHocRequirement(
      decl, C.Id_recordArgument, [](AbstractFunctionDecl *func) {
        return func->isDistributedTargetInvocationEncoderRecordArgument();
      });
}

AbstractFunctionDecl *
GetDistributedTargetInvocationEncoderRecordReturnTypeFunctionRequest::evaluate(
    Evaluator &evaluator, NominalTypeDecl *decl) const {
  auto &C = decl->getASTContext();

  return findDistributedAdHocRequirement(
      decl, C.Id_recordReturnType, [](AbstractFunctionDecl *func) {
        return func->isDistributedTargetInvocationEncoderRecordReturnType();
      });
}

AbstractFunctionDecl *
GetDistributedTargetInvocationEncoderRecordErrorTypeFunctionRequest::evaluate(
    Evaluator &evaluator, NominalTypeDecl *decl) const {
  auto &C = decl->getASTContext();
  return findDistributedAdHocRequirement(
      decl, C.Id_recordErrorType, [](AbstractFunctionDecl *func) {
        return func->isDistributedTargetInvocationEncoderRecordErrorType();
      });
}

AbstractFunctionDecl *
GetDistributedTargetInvocationDecoderDecodeNextArgumentFunctionRequest::evaluate(
    Evaluator &evaluator, NominalTypeDecl *decl) const {
  auto &C = decl->getASTContext();
  return findDistributedAdHocRequirement(
      decl, C.Id_decodeNextArgument, [](AbstractFunctionDecl *func) {
        return func->isDistributedTargetInvocationDecoderDecodeNextArgument();
      });
}

AbstractFunctionDecl *
GetDistributedTargetInvocationResultHandlerOnReturnFunctionRequest::evaluate(
    Evaluator &evaluator, NominalTypeDecl *decl) const {
  auto &C = decl->getASTContext();
  return findDistributedAdHocRequirement(
      decl, C.Id_onReturn, [](AbstractFunctionDecl *func) {
        return func->isDistributedTargetInvocationResultHandlerOnReturn();
      });
}

// ==== ------------------------------------------------------------------------

/// Add Fix-It text for the given protocol type to inherit DistributedActor.
void swift::diagnoseDistributedFunctionInNonDistributedActorProtocol(
    const ProtocolDecl *proto, InFlightDiagnostic &diag) {
  if (proto->getInherited().empty()) {
    SourceLoc fixItLoc = proto->getBraces().Start;
    diag.fixItInsert(fixItLoc, ": DistributedActor");
  } else {
    // Similar to how Sendable FitIts do this, we insert at the end of
    // the inherited types.
    SourceLoc fixItLoc = proto->getInherited().getEndLoc();
    diag.fixItInsertAfter(fixItLoc, ", DistributedActor");
  }
}


/// Add Fix-It text for the given nominal type to adopt Codable.
///
/// Useful when 'Codable' is the 'SerializationRequirement' and a non-Codable
/// function parameter or return value type is detected.
void swift::addCodableFixIt(
    const NominalTypeDecl *nominal, InFlightDiagnostic &diag) {
  if (nominal->getInherited().empty()) {
    SourceLoc fixItLoc = nominal->getBraces().Start;
    diag.fixItInsert(fixItLoc, ": Codable");
  } else {
    SourceLoc fixItLoc = nominal->getInherited().getEndLoc();
    diag.fixItInsertAfter(fixItLoc, ", Codable");
  }
}

// ==== ------------------------------------------------------------------------

bool IsDistributedActorRequest::evaluate(
    Evaluator &evaluator, NominalTypeDecl *nominal) const {
  // Protocols are actors if they inherit from `DistributedActor`.
  if (auto protocol = dyn_cast<ProtocolDecl>(nominal)) {
    auto &ctx = protocol->getASTContext();
    auto *distributedActorProtocol = ctx.getDistributedActorDecl();
    if (!distributedActorProtocol)
      return false;

    return (protocol == distributedActorProtocol ||
            protocol->inheritsFrom(distributedActorProtocol));
  }

  // Class declarations are 'distributed actors' if they are declared with
  // 'distributed actor'
  auto classDecl = dyn_cast<ClassDecl>(nominal);
  if(!classDecl)
    return false;

  return classDecl->isExplicitDistributedActor();
}

// ==== ------------------------------------------------------------------------

static bool checkAdHocRequirementAccessControl(
    NominalTypeDecl *decl,
    ProtocolDecl *proto,
    AbstractFunctionDecl *func) {
  if (!func)
    return true;

  // === check access control
  if (func->getEffectiveAccess() == decl->getEffectiveAccess()) {
    return false;
  }

  func->diagnose(diag::witness_not_accessible_type, diag::RequirementKind::Func,
                 func, /*isSetter=*/false,
                 /*requiredAccess=*/AccessLevel::Public, AccessLevel::Public,
                 proto);
      return true;
}

static bool diagnoseMissingAdHocProtocolRequirement(ASTContext &C, Identifier identifier, NominalTypeDecl *decl) {
  assert(decl);
  auto FixitLocation = decl->getBraces().Start;

  // Prepare the indent (same as `printRequirementStub`)
  StringRef ExtraIndent;
  StringRef CurrentIndent =
      Lexer::getIndentationForLine(C.SourceMgr, decl->getStartLoc(), &ExtraIndent);

  llvm::SmallString<128> Text;
  llvm::raw_svector_ostream OS(Text);
  ExtraIndentStreamPrinter Printer(OS, CurrentIndent);

  Printer.printNewline();
  Printer.printIndent();
  Printer << (decl->getFormalAccess() == AccessLevel::Public ? "public " : "");

  if (identifier == C.Id_remoteCall) {
    Printer << "func remoteCall<Act, Err, Res>("
               "on actor: Act, "
               "target: RemoteCallTarget, "
               "invocation: inout InvocationEncoder, "
               "throwing: Err.Type, "
               "returning: Res.Type) "
               "async throws -> Res "
               "where Act: DistributedActor, "
               "Act.ID == ActorID, "
               "Err: Error, "
               "Res: SerializationRequirement";
  } else if (identifier == C.Id_remoteCallVoid) {
    Printer << "func remoteCallVoid<Act, Err>("
               "on actor: Act, "
               "target: RemoteCallTarget, "
               "invocation: inout InvocationEncoder, "
               "throwing: Err.Type"
               ") async throws "
               "where Act: DistributedActor, "
               "Act.ID == ActorID, "
               "Err: Error";
  } else if (identifier == C.Id_recordArgument) {
    Printer << "mutating func recordArgument<Value: SerializationRequirement>(_ argument: RemoteCallArgument<Value>) throws";
  } else if (identifier == C.Id_recordReturnType) {
    Printer << "mutating func recordReturnType<Res: SerializationRequirement>(_ resultType: Res.Type) throws";
  } else if (identifier == C.Id_decodeNextArgument) {
    Printer << "mutating func decodeNextArgument<Argument: SerializationRequirement>() throws -> Argument";
  } else if (identifier == C.Id_onReturn) {
    Printer << "func onReturn<Success: SerializationRequirement>(value: Success) async throws";
  } else {
    llvm_unreachable("Unknown identifier for diagnosing ad-hoc missing requirement.");
  }

  /// Print the "{ <#code#> }" placeholder body
  Printer << " {\n";
  Printer << ExtraIndent << getCodePlaceholder();
  Printer.printNewline();
  Printer.printIndent();
  Printer << "}\n";

  decl->diagnose(
      diag::distributed_actor_system_conformance_missing_adhoc_requirement,
      decl, identifier);
  decl->diagnose(diag::missing_witnesses_general)
      .fixItInsertAfter(FixitLocation, Text.str());

  return true;
}

bool swift::checkDistributedActorSystemAdHocProtocolRequirements(
    ASTContext &C,
    ProtocolDecl *Proto,
    NormalProtocolConformance *Conformance,
    Type Adoptee,
    bool diagnose) {
  auto decl = Adoptee->getAnyNominal();
  auto anyMissingAdHocRequirements = false;

  // ==== ----------------------------------------------------------------------
  // Check the ad-hoc requirements of 'DistributedActorSystem":
  if (Proto->isSpecificProtocol(KnownProtocolKind::DistributedActorSystem)) {
    // - remoteCall
    auto remoteCallDecl =
        getRemoteCallOnDistributedActorSystem(decl, /*isVoidReturn=*/false);
    if (!remoteCallDecl && diagnose) {
      anyMissingAdHocRequirements = diagnoseMissingAdHocProtocolRequirement(C, C.Id_remoteCall, decl);
    }
    if (checkAdHocRequirementAccessControl(decl, Proto, remoteCallDecl)) {
      anyMissingAdHocRequirements = true;
    }

    // - remoteCallVoid
    auto remoteCallVoidDecl =
        getRemoteCallOnDistributedActorSystem(decl, /*isVoidReturn=*/true);
    if (!remoteCallVoidDecl && diagnose) {
      anyMissingAdHocRequirements = diagnoseMissingAdHocProtocolRequirement(C, C.Id_remoteCallVoid, decl);
    }
    if (checkAdHocRequirementAccessControl(decl, Proto, remoteCallVoidDecl)) {
      anyMissingAdHocRequirements = true;
    }

    return anyMissingAdHocRequirements;
  }

  // ==== ----------------------------------------------------------------------
  // Check the ad-hoc requirements of 'DistributedTargetInvocationEncoder'
  if (Proto->isSpecificProtocol(KnownProtocolKind::DistributedTargetInvocationEncoder)) {
    // - recordArgument
    auto recordArgumentDecl =
        getRecordArgumentOnDistributedInvocationEncoder(decl);
    if (!recordArgumentDecl) {
      anyMissingAdHocRequirements = diagnoseMissingAdHocProtocolRequirement(C, C.Id_recordArgument, decl);
    }
    if (checkAdHocRequirementAccessControl(decl, Proto, recordArgumentDecl)) {
      anyMissingAdHocRequirements = true;
    }

    // - recordReturnType
    auto recordReturnTypeDecl =
        getRecordReturnTypeOnDistributedInvocationEncoder(decl);
    if (!recordReturnTypeDecl) {
      anyMissingAdHocRequirements = diagnoseMissingAdHocProtocolRequirement(C, C.Id_recordReturnType, decl);
    }
    if (checkAdHocRequirementAccessControl(decl, Proto, recordReturnTypeDecl)) {
      anyMissingAdHocRequirements = true;
    }

    return anyMissingAdHocRequirements;
  }

  // ==== ----------------------------------------------------------------------
  // Check the ad-hoc requirements of 'DistributedTargetInvocationDecoder'
  if (Proto->isSpecificProtocol(KnownProtocolKind::DistributedTargetInvocationDecoder)) {
    // - decodeNextArgument
    auto decodeNextArgumentDecl =
        getDecodeNextArgumentOnDistributedInvocationDecoder(decl);
    if (!decodeNextArgumentDecl) {
      anyMissingAdHocRequirements = diagnoseMissingAdHocProtocolRequirement(C, C.Id_decodeNextArgument, decl);
    }
    if (checkAdHocRequirementAccessControl(decl, Proto, decodeNextArgumentDecl)) {
      anyMissingAdHocRequirements = true;
    }

    return anyMissingAdHocRequirements;
  }

  // === -----------------------------------------------------------------------
  // Check the ad-hoc requirements of 'DistributedTargetInvocationResultHandler'
  if (Proto->isSpecificProtocol(KnownProtocolKind::DistributedTargetInvocationResultHandler)) {
    // - onReturn
    auto onReturnDecl =
        getOnReturnOnDistributedTargetInvocationResultHandler(decl);
    if (!onReturnDecl) {
      anyMissingAdHocRequirements = diagnoseMissingAdHocProtocolRequirement(C, C.Id_onReturn, decl);
    }
    if (checkAdHocRequirementAccessControl(decl, Proto, onReturnDecl)) {
      anyMissingAdHocRequirements = true;
    }

    return anyMissingAdHocRequirements;
  }

  assert(!anyMissingAdHocRequirements &&
         "Should have returned in appropriate type checking block earlier!");
  return false;
}

static bool checkDistributedTargetResultType(
    ValueDecl *valueDecl,
    Type serializationRequirement,
    bool diagnose) {
  auto &C = valueDecl->getASTContext();

  if (serializationRequirement->hasError())
    return false; // error of the type would be diagnosed elsewhere

  Type resultType;
  if (auto func = dyn_cast<FuncDecl>(valueDecl)) {
    resultType = func->mapTypeIntoEnvironment(func->getResultInterfaceType());
  } else if (auto var = dyn_cast<VarDecl>(valueDecl)) {
    // Distributed computed properties are always getters,
    // so get the get accessor for mapping the type into context:
    auto getter = var->getAccessor(swift::AccessorKind::Get);
    resultType = getter->mapTypeIntoEnvironment(var->getInterfaceType());
  } else {
    llvm_unreachable("Unsupported distributed target");
  }

  if (resultType->isVoid())
    return false;

  SmallVector<ProtocolDecl *, 4> serializationRequirements;
  // Collect extra "SerializationRequirement: SomeProtocol" requirements
  auto srl = serializationRequirement->getExistentialLayout();
  llvm::copy(srl.getProtocols(), std::back_inserter(serializationRequirements));

  auto isCodableRequirement =
      checkDistributedSerializationRequirementIsExactlyCodable(
          C, serializationRequirement);

  // --- Special case: `-> some/any P` where P is a `@Resolvable protocol`
  // Wire format encodes the actor's `id` as a Codable ActorID,
  // so the existential/opaque does not need to conform to the serialization requirement.
  bool skipCodableCheck = false;
  auto resolvableMatch = findDistributedResolvableExistentialOrOpaqueProtocol(resultType);
  if (resolvableMatch.isAmbiguous) {
    if (diagnose) {
      valueDecl->diagnose(
          diag::distributed_actor_func_result_resolvable_protocol_composition_ambiguous,
          resultType, valueDecl);
      valueDecl->diagnose(
          diag::distributed_actor_func_resolvable_protocol_composition_ambiguous_note);
    }
    return true;
  }

  if (auto *resolvableProto = resolvableMatch.proto) {
    auto protocolSystemTy =
        getResolvableProtocolConcreteActorSystemType(resolvableProto);
    if (!protocolSystemTy) {
      if (diagnose) {
        valueDecl->diagnose(
            diag::distributed_actor_func_result_resolvable_protocol_no_concrete_actor_system,
            resultType, valueDecl, resolvableProto->getName());
      }
      return true;
    }

    auto enclosingSystemTy =
        getConcreteReplacementForProtocolActorSystemType(valueDecl);

    if (enclosingSystemTy && !enclosingSystemTy->isEqual(protocolSystemTy)) {
      if (diagnose) {
        valueDecl->diagnose(
            diag::distributed_actor_func_result_resolvable_actor_system_mismatch,
            resultType, valueDecl,
            resolvableProto->getName(), protocolSystemTy);
        resolvableProto->diagnose(
            diag::distributed_actor_func_result_resolvable_actor_system_mismatch_note,
            resolvableProto->getName(), protocolSystemTy);
      }
      return true;
    }

    // `@Resolvable protocol` result — skip Codable check, wire uses actor ID
    skipCodableCheck = true;
  }

  if (!skipCodableCheck) {
    for (auto serializationReq: serializationRequirements) {
      auto conformance = checkConformance(resultType, serializationReq);
      if (conformance.isInvalid()) {
        if (diagnose) {
          llvm::StringRef conformanceToSuggest = isCodableRequirement ?
                                                 "Codable" : // Codable is a typealias, easier to diagnose like that
                                                 serializationReq->getNameStr();

          auto diag = valueDecl->diagnose(
              diag::distributed_actor_target_result_not_codable,
              resultType,
              valueDecl,
              conformanceToSuggest
          );

          if (isCodableRequirement) {
            if (auto resultNominalType = resultType->getAnyNominal()) {
              addCodableFixIt(resultNominalType, diag);
            }
          }
        }

        return true;
      }
    }
  }

  return false;
}

bool swift::checkDistributedActorSystem(const NominalTypeDecl *system) {
  auto nominal = const_cast<NominalTypeDecl *>(system);

  // ==== Ensure the Distributed module is available,
  // without it there's no reason to check the decl in more detail anyway.
  if (!swift::ensureDistributedModuleLoaded(nominal))
    return true;

  // === AssociatedTypes
  // --- SerializationRequirement MUST be a protocol TODO(distributed): rdar://91663941
  // we may lift this in the future and allow classes but this requires more
  // work to enable associatedtypes to be constrained to class or protocol,
  // which then will unlock using them as generic constraints in protocols.
  Type requirementTy = getDistributedActorSystemSerializationType(nominal);

  if (auto existentialTy = requirementTy->getAs<ExistentialType>()) {
    requirementTy = existentialTy->getConstraintType();
  }

  if (auto alias = dyn_cast<TypeAliasType>(requirementTy.getPointer())) {
    auto concreteReqTy = alias->getDesugaredType();
    if (isa<ProtocolCompositionType>(concreteReqTy)) {
      // ok, protocol composition is fine as requirement,
      // since special case of just a single protocol
    } else if (isa<ProtocolType>(concreteReqTy)) {
      // ok, protocols is exactly what we want to be used as constraints here
    } else {
      nominal->diagnose(diag::distributed_actor_system_serialization_req_must_be_protocol,
                        requirementTy);
      return true;
    }
  }

  // all good, didn't find any errors
  return false;
}

/// Check whether the function is a proper distributed function
///
/// \returns \c true if there was a problem with adding the attribute, \c false
/// otherwise.
bool swift::checkDistributedFunction(AbstractFunctionDecl *func) {
  if (!func->isDistributed())
    return false;

  // ==== Ensure the Distributed module is available,
  if (!swift::ensureDistributedModuleLoaded(func))
    return true;

  auto &C = func->getASTContext();
  return evaluateOrDefault(C.evaluator,
                           CheckDistributedFunctionRequest{func},
                           false); // no error if cycle
}

/// Emit a fix-it suggesting to constrain the `@Resolvable` \p resolvableProto's
/// `Self.ActorSystem` to the enclosing actor's system type (or a placeholder
/// when no concrete enclosing system is known).
static void emitResolvableProtocolMissingActorSystemFixit(
    ProtocolDecl *resolvableProto, Type enclosingSystemTy) {
  auto fixItLoc = resolvableProto->getBraces().Start;
  if (!fixItLoc.isValid())
    return;

  llvm::SmallString<64> fixIt;
  fixIt += " where Self.ActorSystem == ";
  if (enclosingSystemTy && !enclosingSystemTy->hasError() &&
      !enclosingSystemTy->is<GenericTypeParamType>() &&
      !enclosingSystemTy->is<ArchetypeType>()) {
    fixIt += enclosingSystemTy->getString();
  } else {
    fixIt += "<#ActorSystem#>";
  }
  fixIt += " ";
  resolvableProto
      ->diagnose(
          diag::distributed_actor_func_param_resolvable_protocol_no_concrete_actor_system_fixit,
          resolvableProto->getName())
      .fixItInsert(fixItLoc, fixIt);
}

bool CheckDistributedFunctionRequest::evaluate(
    Evaluator &evaluator, AbstractFunctionDecl *func) const {
  if (auto *accessor = dyn_cast<AccessorDecl>(func)) {
    auto *var = cast<VarDecl>(accessor->getStorage());
    assert(var->isDistributed() && accessor->isDistributedGetter());
  } else {
    assert(func->isDistributed());
  }

  auto &C = func->getASTContext();

  /// If no distributed module is available, then no reason to even try checks.
  if (!C.getLoadedModule(C.Id_Distributed)) {
    func->diagnose(diag::distributed_decl_needs_explicit_distributed_import,
                   func);
    return true;
  }

  Type serializationReqType =
      getDistributedActorSerializationType(func->getDeclContext());

  for (auto param: *func->getParameters()) {
    // --- Check the parameter conforming to serialization requirements
    if (!serializationReqType->hasError()) {
      // If the requirement is exactly `Codable` we diagnose it ia bit nicer.
      auto serializationRequirementIsCodable =
          checkDistributedSerializationRequirementIsExactlyCodable(
              C, serializationReqType);

      // --- Check parameters for 'SerializationRequirement' conformance
      auto paramTy = func->mapTypeIntoEnvironment(param->getInterfaceType());

      // --- Special case: `param: some/any P` where P is a `@Resolvable protocol`.
      bool skipSerializationRequirementCheck = false;
      auto resolvableMatch = findDistributedResolvableExistentialOrOpaqueProtocol(paramTy);
      if (resolvableMatch.isAmbiguous) {
        func->diagnose(
            diag::distributed_actor_func_param_resolvable_protocol_composition_ambiguous,
            param->getArgumentName(), param->getInterfaceType(), func);
        func->diagnose(
            diag::distributed_actor_func_resolvable_protocol_composition_ambiguous_note);
        return true;
      }

      if (auto *resolvableProto = resolvableMatch.proto) {
        auto enclosingSystemTy =
            getConcreteReplacementForProtocolActorSystemType(func);
        auto protocolSystemTy =
            getResolvableProtocolConcreteActorSystemType(resolvableProto);
        if (!protocolSystemTy) {
          func->diagnose(
              diag::distributed_actor_func_param_resolvable_protocol_no_concrete_actor_system,
              param->getArgumentName(), param->getInterfaceType(), func,
              resolvableProto->getName());
          emitResolvableProtocolMissingActorSystemFixit(resolvableProto,
                                                       enclosingSystemTy);
          return true;
        }

        if (enclosingSystemTy && !enclosingSystemTy->isEqual(protocolSystemTy)) {
          // The actor system of the `any P` and actor we're making the call on
          // must match, because we need to form a `$P.resolve(param.id, using: self.system)`
          // call.
          func->diagnose(
              diag::distributed_actor_func_param_resolvable_actor_system_mismatch,
              param->getArgumentName(), param->getInterfaceType(), func,
              resolvableProto->getName(), protocolSystemTy,
              enclosingSystemTy);
          resolvableProto->diagnose(
              diag::distributed_actor_func_param_resolvable_actor_system_mismatch_note,
              resolvableProto->getName(), protocolSystemTy);
          return true;
        }

        // Skip the serialization-requirement check for this parameter;
        // We know it is a distributed actor protocol on the same actor system.
        // We also know that it is a `@Resolvable protocol` and `any/some P`,
        // which does itself not conform to e.g. `Codable`
        skipSerializationRequirementCheck = true;
      }

      if (!skipSerializationRequirementCheck) {
        auto srl = serializationReqType->getExistentialLayout();
        for (auto req: srl.getProtocols()) {
          if (!checkConformance(paramTy, req)) {
            auto diag = func->diagnose(
                diag::distributed_actor_func_param_not_codable,
                param->getArgumentName(), param->getInterfaceType(), func,
                serializationRequirementIsCodable ? "Codable"
                                                  : req->getNameStr());

            if (auto paramNominalTy = paramTy->getAnyNominal()) {
              addCodableFixIt(paramNominalTy, diag);
            } // else, no nominal type to suggest the fixit for, e.g. a closure

            return true;
          }
        }
      }
    }

    // --- Check parameters for various illegal modifiers
    if (param->isInOut()) {
      param->diagnose(
          diag::distributed_actor_func_inout,
          param->getName(),
          func
      ).fixItRemove(SourceRange(param->getTypeSourceRangeForDiagnostics().Start,
                                param->getTypeSourceRangeForDiagnostics().Start.getAdvancedLoc(1)));
      // FIXME(distributed): the fixIt should be on param->getSpecifierLoc(), but that Loc is invalid for some reason?
      return true;
    }

    if (param->getSpecifier() == ParamSpecifier::LegacyShared ||
        param->getSpecifier() == ParamSpecifier::LegacyOwned ||
        param->getSpecifier() == ParamSpecifier::Consuming ||
        param->getSpecifier() == ParamSpecifier::Borrowing) {
      param->diagnose(
          diag::distributed_actor_func_unsupported_specifier,
          ParamDecl::getSpecifierSpelling(param->getSpecifier()),
          param->getName(),
          func);
      return true;
    }

    if (param->isVariadic()) {
      param->diagnose(
          diag::distributed_actor_func_variadic,
          param->getName(),
          func
      );
    }
  }

  // --- Result type must be either void or a serialization requirement conforming type
  if (checkDistributedTargetResultType(func, serializationReqType,
                                       /*diagnose=*/true)) {
    return true;
  }

  return false;
}

/// Check whether the function is a proper distributed computed property
///
/// \param diagnose Whether to emit a diagnostic when a problem is encountered.
///
/// \returns \c true if there was a problem with adding the attribute, \c false
/// otherwise.
bool swift::checkDistributedActorProperty(VarDecl *var, bool diagnose) {
  // without the distributed module, we can't check any of these.
  if (!ensureDistributedModuleLoaded(var))
    return true;

  /// === Check if the declaration is a valid combination of attributes
  if (var->isStatic()) {
    if (diagnose)
      var->diagnose(diag::distributed_property_cannot_be_static,
                    var->getName());
    // TODO(distributed): fixit, offer removing the static keyword
    return true;
  }

  // it is not a computed property
  if (var->isLet() || var->hasStorageOrWrapsStorage()) {
    if (diagnose)
      var->diagnose(diag::distributed_property_can_only_be_computed, var);
    return true;
  }

  // distributed properties cannot have setters
  if (var->getWriteImpl() != swift::WriteImplKind::Immutable) {
    if (diagnose)
      var->diagnose(diag::distributed_property_can_only_be_computed_get_only,
                    var->getName());
    return true;
  }

  auto serializationRequirement =
      getDistributedActorSerializationType(var->getDeclContext());

  if (checkDistributedTargetResultType(var, serializationRequirement, diagnose)) {
    return true;
  }

  return false;
}

// ==== ------------------------------------------------------------------------
// MARK: Attribute inheritance from protocol requirements

/// Synthesize a real `CustomAttr` for `@<macroName><argText>` (e.g.
/// `@Entitlement("com.example.foo")`) at the witness's source location, by
/// installing the attribute text as a memory buffer, wrapping it in a
/// SourceFile, and running the parser. Returns nullptr if the surrounding
/// declaration context lacks a source file (e.g. Clang-imported witnesses).
///
/// This is the cross-module inheritance path: the requirement's `CustomAttr`
/// was deserialized from another module and has no valid `AtLoc`, so the
/// attached-macro plugin cannot find an `AttributeSyntax` node to walk.
/// Synthesizing a real source buffer here produces a `CustomAttr` whose
/// `AtLoc` points into a parsed `AttributeSyntax`, which the plugin's
/// `swift_Macros_expandAttachedMacro` entrypoint requires.
///
/// The pattern mirrors `ClangImporter::Implementation::getClangSwiftAttrSourceFile`
/// / `importNontrivialAttribute`, which uses `AttributeFromClang` generated
/// source buffers plus `parseExpandedAttributeList` to turn a raw attribute
/// string into a real parsed attribute.
static CustomAttr *
synthesizeCustomAttrForWitness(ValueDecl *witness, StringRef macroName,
                               StringRef argText) {
  auto *witnessSF = witness->getDeclContext()->getParentSourceFile();
  if (!witnessSF)
    return nullptr;
  (void)witnessSF;

  ASTContext &ctx = witness->getASTContext();
  SourceManager &SM = ctx.SourceMgr;
  auto *module = witness->getDeclContext()->getParentModule();

  // Compose the attribute source text: `@<MacroName><argText>`. `argText`
  // already includes the parentheses (it was extracted from
  // `ArgumentList::getSourceRange()` at serialization time).
  llvm::SmallString<128> attrText;
  attrText += "@";
  attrText += macroName;
  attrText += argText;

  // Buffer name embeds the macro name so any diagnostic emitted from within
  // the synthesized file points back at something meaningful.
  llvm::SmallString<64> bufferName;
  bufferName += "<inherited-attr @";
  bufferName += macroName;
  bufferName += " on ";
  bufferName += witness->getBaseName().userFacingName();
  bufferName += ">";

  auto buffer = llvm::MemoryBuffer::getMemBufferCopy(attrText, bufferName);
  unsigned bufferID = SM.addNewSourceBuffer(std::move(buffer));

  // Register the buffer as a generated source rooted at the witness's loc.
  // `AttributeFromClang` is exactly the right kind: it turns
  // `parseExpandedAttributeList` on when the file is parsed, and it teaches
  // `getExportedSourceFile` to bridge to ASTGen so `swift_Macros_...` can
  // find the `AttributeSyntax`.
  //
  // `astNode` is set to the witness itself. The `SourceFileKind::SyntheticMacro`
  // path in `AvailabilityScope::createForSourceFile` reads
  // `getNodeInEnclosingSourceFile().getStartLoc()` from this field to locate
  // the buffer inside the enclosing source file for parent-scope inheritance.
  // Setting it to the witness (rather than the module) yields a valid loc.
  GeneratedSourceInfo sourceInfo{
      GeneratedSourceInfo::AttributeFromClang,
      /*originalSourceRange=*/CharSourceRange(witness->getLoc(), 0),
      SM.getRangeForBuffer(bufferID),
      /*astNode=*/ASTNode(witness).getOpaqueValue(),
      /*declContext=*/witness->getDeclContext(),
      /*attachedMacroCustomAttr=*/nullptr};
  SM.setGeneratedSourceInfo(bufferID, sourceInfo);

  // Wrap the buffer in a `SyntheticMacro`-kind SourceFile parented to the
  // witness's module. `getTopLevelDecls()` triggers the parser's dispatch on
  // `GeneratedSourceInfo::AttributeFromClang`, which calls
  // `parseExpandedAttributeList` and returns a `MissingDecl` carrying the
  // parsed attribute list.
  //
  // Using `SyntheticMacro` (rather than `Library`) is what makes
  // `AvailabilityScope::createForSourceFile` walk `SF->getEnclosingSourceFile()`
  // and inherit the witness's availability context. Without this, the
  // synthesized buffer's root availability scope defaults to the module's
  // deployment target, and any reference to `@available(SwiftStdlib X, *)` API
  // from inside the inherited attribute would fail to type-check even when the
  // witness itself is in a properly guarded `@available(SwiftStdlib X, *)`
  // context. See `lib/AST/AvailabilityScope.cpp` `createForSourceFile`.
  auto *attrSF = new (ctx) SourceFile(*module, SourceFileKind::SyntheticMacro,
                                      bufferID, /*parsingOpts=*/{},
                                      /*isPrimary=*/false);

  for (auto *decl : attrSF->getTopLevelDecls()) {
    for (auto *attr : decl->getAttrs()) {
      if (auto *custom = dyn_cast<CustomAttr>(attr)) {
        // Retarget owner to the witness; the attribute is otherwise ready
        // to be attached with valid `AtLoc`, `TypeExpr`, and `ArgumentList`
        // source locations inside our synthesized buffer.
        custom->attachToDecl(witness);
        return custom;
      }
    }
  }

  return nullptr;
}

/// Clone allow-listed distributed-validation attributes (`@Entitlement`,
/// `@ValidateRemoteCall`) from a protocol requirement onto its witness on
/// the given nominal type.
///
/// This runs early, from `checkDistributedActor` — before per-member type
/// checking triggers peer macro expansion on the witness. That ordering is
/// what makes the feature work: by the time the peer macro reads the
/// witness's attribute list, the inherited attributes are already there,
/// and the macro emits a section record against the concrete method as if
/// the user had written the annotation there directly.
///
/// The clone is marked implicit; `owner` is retargeted to the witness. The
/// argument list is preserved verbatim.
///
/// Matching is by full `DeclName` (including argument labels) — a
/// `distributed func openDoor()` requirement matches a
/// `distributed func openDoor()` witness. No signature matching yet;
/// distributed funcs with overloads across protocol/actor pairs would
/// need more care (follow-up if it becomes a real case).
void swift::inheritDistributedValidationAttrs(NominalTypeDecl *nominal) {
  // Only concrete conformers (protocols themselves have nothing to
  // inherit onto).
  if (isa<ProtocolDecl>(nominal))
    return;

  ASTContext &ctx = nominal->getASTContext();

  auto isAllowListed = [&](StringRef name) {
    return name == "Entitlement" || name == "ValidateRemoteCall";
  };

  // Attribute's spelled base identifier, e.g. "Entitlement" for
  // `@Entitlement("...")`. Returns empty StringRef when the attribute has no
  // decl-ref TypeRepr (should not happen for a well-formed macro attribute).
  // Deliberately does NOT call `getResolvedMacro()`, which triggers name
  // resolution on the attribute's argument list - deserialized args have
  // invalid SourceLocs and crash the constraint solver's decl-ref resolver.
  auto attrBaseName = [&](CustomAttr *attr) -> StringRef {
    if (auto *typeRepr = attr->getTypeRepr()) {
      if (auto *declRefRepr = dyn_cast<DeclRefTypeRepr>(typeRepr)) {
        return declRefRepr->getNameRef().getBaseName().userFacingName();
      }
    }
    return StringRef();
  };

  auto witnessAlreadyHas = [&](ValueDecl *witness, CustomAttr *reqAttr,
                               StringRef reqName) {
    for (auto *existing : witness->getAttrs().getAttributes<CustomAttr>()) {
      if (attrBaseName(const_cast<CustomAttr *>(existing)) == reqName) {
        auto lhsRange = reqAttr->getArgs()
            ? reqAttr->getArgs()->getSourceRange()
            : SourceRange();
        auto rhsRange = existing->getArgs()
            ? existing->getArgs()->getSourceRange()
            : SourceRange();
        if (lhsRange == rhsRange) return true;
      }
    }
    return false;
  };

  auto cloneOnto = [&](ValueDecl *witness, CustomAttr *reqAttr,
                       StringRef macroName) {
    // Same-module clone: the requirement's `TypeExpr` and `ArgumentList`
    // already carry valid source locations. Reuse them verbatim; the peer
    // macro plugin will walk the same `AttributeSyntax` the user wrote on
    // the protocol requirement, which is fine.
    if (reqAttr->AtLoc.isValid()) {
      auto *cloned = CustomAttr::create(ctx, reqAttr->AtLoc,
                                        reqAttr->getTypeExpr(),
                                        /*owner=*/witness,
                                        reqAttr->getInitContext(),
                                        reqAttr->getArgs(),
                                        /*implicit=*/true);
      witness->getAttrs().add(cloned);
      return;
    }

    // Cross-module clone: `reqAttr` was deserialized from another module
    // and has no valid `AtLoc`. Synthesize a real attribute source buffer
    // at the witness's location and parse it, so the attached-macro
    // plugin can walk a real `AttributeSyntax` (its
    // `swift_Macros_expandAttachedMacro` entrypoint requires that).
    //
    // The arg-list source text is preserved on the requirement's
    // `CustomAttr` by `@preservedInInterface` serialization; we
    // deliberately do NOT clear `preservedArgText` in
    // `materializePreservedCustomAttrArgs` so it's available here.
    StringRef argText = reqAttr->getPreservedArgText();
    if (auto *synthesized =
            synthesizeCustomAttrForWitness(witness, macroName, argText)) {
      witness->getAttrs().add(synthesized);
    }
  };

  // Walk every protocol this nominal conforms to (directly or transitively
  // through refinements). For each `distributed` requirement, find the
  // same-named witness on the nominal and clone allow-listed attributes.
  //
  // Cross-module: when the protocol is imported from another module, its
  // `@Entitlement` / `@ValidateRemoteCall` `CustomAttr`s survive
  // serialization because their macro declarations opt in via
  // `@preservedInInterface`. The argument list arrives as preserved source
  // text and is materialized into an `ArgumentList` inside the fast-filter
  // loop below before we consult `reqAttr->getArgs()`.
  for (auto *conformance : nominal->getAllConformances(/*sorted=*/false)) {
    auto *proto = conformance->getProtocol();
    for (auto *reqMember : proto->getMembers()) {
      auto *req = dyn_cast<ValueDecl>(reqMember);
      if (!req || !req->isDistributed())
        continue;

      // Fast filter: does the requirement carry any allow-listed
      // `CustomAttr`? Materialize preserved arg-list text on all
      // `CustomAttr`s here first so the plugin expander sees a proper
      // `ArgumentList` on the cloned witness attribute.
      //
      // The check uses the attribute's spelled type name (via `TypeRepr`)
      // rather than `getResolvedMacro()`. Macro resolution needs to type
      // check the argument list; on a deserialized `CustomAttr` those args
      // have invalid `SourceLoc`s (they came out of `preservedArgText`),
      // which crashes the constraint solver's decl-ref resolver. The
      // spelled type name is enough to filter, since we only accept
      // `@Entitlement` / `@ValidateRemoteCall` which have unique names.
      for (auto *reqAttr : req->getAttrs().getAttributes<CustomAttr>()) {
        materializePreservedCustomAttrArgs(
            const_cast<CustomAttr *>(reqAttr), req->getDeclContext());
      }
      bool hasAny = false;
      for (auto *reqAttr : req->getAttrs().getAttributes<CustomAttr>()) {
        if (isAllowListed(attrBaseName(const_cast<CustomAttr *>(reqAttr)))) {
          hasAny = true;
          break;
        }
      }
      if (!hasAny) continue;

      // Find the corresponding witness on the nominal by full DeclName.
      // A `distributed` requirement can only be satisfied by a `distributed`
      // witness (enforced elsewhere), so we further filter by that.
      //
      // `ExcludeMacroExpansions` is CRITICAL here. Without it, `lookupDirect`
      // fires `populateLookupTableEntryFromMacroExpansions` which calls
      // `visitAuxiliaryDecls` which evaluates and CACHES
      // `ExpandPeerMacroRequest{witness}` under the pre-clone attribute
      // list. Our subsequent `cloneOnto` call adds the inherited attribute
      // but the request cache is already stale - downstream consumers read
      // the cached array and never see the inherited attribute's section
      // record. Skipping macro-expanded candidates here defers peer
      // expansion until after all inherited attrs are attached; the first
      // legitimate `ExpandPeerMacroRequest` then sees the merged list.
      //
      // Trade-off: this lookup will not find a distributed-func witness
      // that is itself synthesized by a peer macro. Distributed funcs are
      // essentially always user-written today, so this is acceptable; if
      // it becomes a real case, fall back to a full lookup when the
      // excluded lookup returns empty.
      using LookupFlags = NominalTypeDecl::LookupDirectFlags;
      auto lookupFlags = OptionSet<LookupFlags>()
          | LookupFlags::ExcludeMacroExpansions;
      for (auto *candidate : nominal->lookupDirect(req->getName(),
                                                    SourceLoc(),
                                                    lookupFlags)) {
        auto *witness = candidate;
        if (!witness->isDistributed()) continue;

        for (auto *reqAttr : req->getAttrs().getAttributes<CustomAttr>()) {
          StringRef name = attrBaseName(const_cast<CustomAttr *>(reqAttr));
          if (!isAllowListed(name)) continue;
          if (witnessAlreadyHas(witness, const_cast<CustomAttr *>(reqAttr),
                                name))
            continue;
          cloneOnto(witness, const_cast<CustomAttr *>(reqAttr), name);
        }
      }
    }
  }
}

// ==== ------------------------------------------------------------------------

void TypeChecker::checkDistributedActor(SourceFile *SF, NominalTypeDecl *nominal) {
  if (!nominal || !nominal->isDistributedActor())
    return;

  // ==== Ensure the Distributed module is available,
  // without it there's no reason to check the decl in more detail anyway.
  if (!swift::ensureDistributedModuleLoaded(nominal))
    return;

  if (nominal->getFormalAccess() == AccessLevel::Open) {
    // we should have outright banned 'open' for all actors, but seems we didn't.
    // distributed actor synthesis always previously crashed if someone were to
    // declare one as open, so we're banning it now, rather than leave it crashing.
    (void) nominal->diagnose(diag::access_control_open_bad_decl);
  }

  auto &C = nominal->getASTContext();
  auto loc = nominal->getLoc();
  recordRequiredImportAccessLevelForDecl(C.getDistributedActorDecl(), nominal,
                                         nominal->getEffectiveAccess(), loc);

  // ==== Constructors
  // --- Get the default initializer
  // If applicable, this will create the default 'init(transport:)' initializer
  (void)nominal->getDefaultInitializer();

  // ==== Clone allow-listed validation attributes from protocol requirements
  // ==== onto their witnesses. This is what makes @Entitlement /
  // ==== @ValidateRemoteCall on a protocol requirement produce a section
  // ==== record on the concrete witness - the macro reads the witness's
  // ==== attributes and expands as if the user had written the annotation
  // ==== there directly.
  //
  // NOTE: this is a belt-and-suspenders call. The actual guarantee that a
  // witness's peer expansion sees the merged (local + inherited) attribute
  // list comes from a hook at the top of `ExpandPeerMacroRequest::evaluate`
  // (see `lib/Sema/TypeCheckMacros.cpp`), which calls
  // `inheritDistributedValidationAttrs` before iterating the witness's
  // attributes. That hook is what makes SAME-KIND stacking work (local
  // `@Entitlement(A)` + inherited `@Entitlement(B)` on the same witness):
  // when the witness already carries a local same-kind attribute, its peer
  // request fires early (during the `getDefaultInitializer()` `init` lookup)
  // and would otherwise cache a stale single-record result. The hook clones
  // the inherited attribute in-line so the very first evaluation emits both
  // records.
  //
  // This explicit call is kept because it runs AFTER `getDefaultInitializer`
  // so it does not force early expansion of a cross-module synthesized
  // attribute (which would trip an availability check before the actor's
  // availability scope is fully built); `inheritDistributedValidationAttrs`
  // is idempotent (dedupes via `witnessAlreadyHas`).
  inheritDistributedValidationAttrs(nominal);

  for (auto member : nominal->getMembers()) {
    // --- Ensure 'distributed func' all thunks
    if (auto *var = dyn_cast<VarDecl>(member)) {
      if (!var->isDistributed())
        continue;

      if (auto thunk = var->getDistributedThunk())
        SF->addDelayedFunction(thunk);

      continue;
    }

    // --- Ensure 'distributed func' all thunks
    if (auto func = dyn_cast<AbstractFunctionDecl>(member)) {
      if (auto dtor = dyn_cast<DestructorDecl>(func)) {
        ASTContext &C = dtor->getASTContext();
        auto selfDecl = dtor->getImplicitSelfDecl();
        selfDecl->addAttribute(new (C) KnownToBeLocalAttr(true));
      }
      if (!func->isDistributed())
        continue;

      if (!isa<ProtocolDecl>(nominal)) {
        auto systemTy = getConcreteReplacementForProtocolActorSystemType(func);
        if (!systemTy || systemTy->hasError()) {
          nominal->diagnose(
              diag::distributed_actor_conformance_missing_system_type,
              nominal->getName());
          return;
        }
      }

      if (auto thunk = func->getDistributedThunk()) {
        SF->addDelayedFunction(thunk);
      }
    }
  }
}

bool TypeChecker::checkDistributedFunc(FuncDecl *func) {
  return swift::checkDistributedFunction(func);
}

ConstructorDecl*
GetDistributedRemoteCallTargetInitFunctionRequest::evaluate(
    Evaluator &evaluator,
    NominalTypeDecl *nominal) const {
  auto &C = nominal->getASTContext();

  // not via `ensureDistributedModuleLoaded` to avoid generating a warning,
  // we won't be emitting the offending decl after all.
  if (!C.getLoadedModule(C.Id_Distributed))
    return nullptr;

  if (!nominal->getDeclaredInterfaceType()->isEqual(
          C.getRemoteCallTargetType()))
    return nullptr;

  for (auto value : nominal->getMembers()) {
    auto ctor = dyn_cast<ConstructorDecl>(value);
    if (!ctor)
      continue;

    auto params = ctor->getParameters();
    if (params->size() != 1)
      return nullptr;

    // _ identifier
    if (params->get(0)->getArgumentName().empty())
      return ctor;

    return nullptr;
  }

  return nullptr;
}

ConstructorDecl*
GetDistributedRemoteCallArgumentInitFunctionRequest::evaluate(
    Evaluator &evaluator,
    NominalTypeDecl *nominal) const {
  auto &C = nominal->getASTContext();

  // not via `ensureDistributedModuleLoaded` to avoid generating a warning,
  // we won't be emitting the offending decl after all.
  if (!C.getLoadedModule(C.Id_Distributed))
    return nullptr;

  if (!nominal->getDeclaredInterfaceType()->isEqual(
          C.getRemoteCallArgumentType()))
    return nullptr;

  for (auto value : nominal->getMembers()) {
    auto ctor = dyn_cast<ConstructorDecl>(value);
    if (!ctor)
      continue;

    auto params = ctor->getParameters();
    if (params->size() != 3)
      return nullptr;

    // --- param: label
    if (!params->get(0)->getArgumentName().is("label"))
      return nullptr;

    // --- param: name
    if (!params->get(1)->getArgumentName().is("name"))
      return nullptr;

    // --- param: value
    if (params->get(2)->getArgumentName() != C.Id_value)
      return nullptr;

    return ctor;
  }

  return nullptr;
}

NominalTypeDecl *
GetDistributedActorInvocationDecoderRequest::evaluate(Evaluator &evaluator,
                                                      NominalTypeDecl *actor) const {
  auto &ctx = actor->getASTContext();
  auto decoderTy = getAssociatedTypeOfDistributedSystemOfActor(
      actor, ctx.Id_InvocationDecoder);
  return decoderTy->getAnyNominal();
}

FuncDecl *
GetDistributedActorConcreteArgumentDecodingMethodRequest::evaluate(
    Evaluator &evaluator, NominalTypeDecl *decl) const {
  auto &ctx = decl->getASTContext();

  if (auto actor = dyn_cast<ClassDecl>(decl)) {
    auto *decoder = getDistributedActorInvocationDecoder(actor);
    // If distributed actor is generic over actor system, there is not
    // going to be a concrete decoder.
    if (!decoder)
      return nullptr;

    auto decoderTy = decoder->getDeclaredInterfaceType();

    auto members =
        TypeChecker::lookupMember(actor->getDeclContext(), decoderTy,
                                  DeclNameRef(ctx.Id_decodeNextArgument));

    // typealias SerializationRequirement = any ...
    auto serializationTy = getAssociatedTypeOfDistributedSystemOfActor(
        actor, ctx.Id_SerializationRequirement);

    if (!serializationTy->is<ExistentialType>())
      return nullptr;

    SmallVector<ProtocolDecl *, 4> serializationRequirements;
    {
      auto layout = serializationTy->getExistentialLayout();
      llvm::copy(layout.getProtocols(),
                 std::back_inserter(serializationRequirements));
    }

    SmallVector<FuncDecl *, 2> candidates;
    // Looking for `decodeNextArgument<Arg: <SerializationReq>>() throws -> Arg`
    for (auto &member : members) {
      auto *FD = dyn_cast<FuncDecl>(member.getValueDecl());
      if (!FD || FD->hasAsync() || !FD->hasThrows())
        continue;

      auto *params = FD->getParameters();
      // No arguments.
      if (params->size() != 0)
        continue;

      auto genericParamList = FD->getGenericParams();
      // A single generic parameter.
      if (genericParamList->size() != 1)
        continue;

      auto paramTy =
          genericParamList->getParams()[0]->getDeclaredInterfaceType();

      // `decodeNextArgument` should return its generic parameter value
      if (!FD->getResultInterfaceType()->isEqual(paramTy))
        continue;

      // Let's find out how many serialization requirements does this method cover e.g. `Codable` is two requirements - `Encodable` and `Decodable`.
      auto nextArgumentSig = FD->getGenericSignature();
      bool okay =
          llvm::all_of(serializationRequirements, [&](ProtocolDecl *p) -> bool {
            return nextArgumentSig->requiresProtocol(paramTy, p);
          });

      // If the current method covers all of the serialization requirements,
      // it's a match. Note that it might also have other requirements, but
      // we let that go as long as there are no two candidates that differ
      // only in generic requirements.
      if (okay)
        candidates.push_back(FD);
    }

    // Type-checker should reject any definition of invocation decoder
    // that doesn't have a correct version of `decodeNextArgument` declared.
    assert(candidates.size() == 1);
    return candidates.front();
  }

  /// No concrete candidate found, return null and perform the call via a
  /// witness
  return nullptr;
}
