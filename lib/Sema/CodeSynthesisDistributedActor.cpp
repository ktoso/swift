//===--- CodeSynthesis.cpp - Type Checking for Declarations ---------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#include "CodeSynthesis.h"

#include "TypeChecker.h"
#include "TypeCheckDecl.h"
#include "TypeCheckObjC.h"
#include "TypeCheckType.h"
#include "swift/AST/ASTPrinter.h"
#include "swift/AST/Availability.h"
#include "swift/AST/Expr.h"
#include "swift/AST/GenericEnvironment.h"
#include "swift/AST/Initializer.h"
#include "swift/AST/ParameterList.h"
#include "swift/AST/PrettyStackTrace.h"
#include "swift/AST/ProtocolConformance.h"
#include "swift/AST/SourceFile.h"
#include "swift/AST/TypeCheckRequests.h"
#include "swift/Basic/Defer.h"
#include "swift/ClangImporter/ClangModule.h"
#include "swift/Sema/ConstraintSystem.h"
#include "llvm/ADT/SmallString.h"
#include "llvm/ADT/StringExtras.h"
#include "DerivedConformances.h"
using namespace swift;

/******************************************************************************/
/************************************ MISC ************************************/
/******************************************************************************/

static std::pair<BraceStmt *, bool>
synthesizeStubBody(AbstractFunctionDecl *fn, void *);

/******************************************************************************/
/*********************************** TYPES ************************************/
/******************************************************************************/

/// Return the `DistributedActorStorage<Self.DistributedActorLocalStorage>`
/// specific to this distributed actor.
static BoundGenericEnumType*
getBoundPersonalityStorageType(ASTContext &C, NominalTypeDecl *decl) {
  fprintf(stderr, "[%s:%d] (%s) getBoundPersonalityStorageType\n", __FILE__, __LINE__, __FUNCTION__);

  // === DistributedActorStorage<?>
  auto *storageDecl = C.getDistributedActorStorageDecl();
  storageDecl->dump();

  // === locate the synthesized: DistributedActorLocalStorage
//  auto localStorageDecls = decl->lookupDirect(DeclName(C.Id_DistributedActorLocalStorage));
////  if (localStorageDecls.size() > 1) {
////    assert(false && "Only a single DistributedActorLocalStorage type may be declared!");
////  }
//  ValueDecl *localStorageDecl = nullptr;
//  for (auto decl : localStorageDecls) {
//    fprintf(stderr, "\n");
//    fprintf(stderr, "[%s:%d] (%s) DECL:\n", __FILE__, __LINE__, __FUNCTION__);
//    decl->dump();
//
//    fprintf(stderr, "\n");
//      localStorageDecl = decl;
////    if (auto structDecl = dyn_cast<StructDecl>(decl)) {
////      localStorageDecl = structDecl;
////      break;
////    }
//  }
  auto localStorageDecl = C.getFAKE_LocalStorageDecl();
  assert(localStorageDecl && "unable to lookup synthesized struct DistributedActorLocalStorage!");
//  assert(localStorageDecl && "unable to lookup synthesized struct DistributedActorLocalStorage!");
//  TypeDecl *localStorageTypeDecl = dyn_cast<TypeDecl>(localStorageDecl);
//  if (!localStorageTypeDecl) {
//    // TODO: diagnose here
//    assert(false && "could not find DistributedActorLocalStorage in distributed actor");
//  }

    // === bind: DistributedActorStorage<DistributedActorLocalStorage>
  auto localStorageType = localStorageDecl->getDeclaredInterfaceType();
//  auto localStorageType = localStorageDecl->getInterfaceType();
//    if (isa<TypeAliasDecl>(localStorageType)) // TODO: doug, ??????
//      localStorageType = localStorageType->getAnyNominal();

  return BoundGenericEnumType::get(
      storageDecl, /*Parent=*/Type(), {localStorageType});
}

static void addImplicitDistributedActorTypeAliases(ClassDecl *actorDecl) {
  assert(actorDecl->isDistributedActor());
  auto &C = actorDecl->getASTContext();

  // ```
  // typealias DistributedActorLocalStorage = ...
  // ```
  {
    // TODO: this is a bit duplicated
    auto localStorageTypeDecls = actorDecl->lookupDirect(DeclName(C.Id_DistributedActorLocalStorage));
    if (localStorageTypeDecls.size() > 1) {
      assert(false && "Only a single DistributedActorLocalStorage type may be declared!");
    }
    TypeDecl *localStorageTypeDecl = dyn_cast<TypeDecl>(localStorageTypeDecls.front());
    Type localStorageType = localStorageTypeDecl->getDeclaredInterfaceType();


    auto *aliasDecl = new (C) TypeAliasDecl(SourceLoc(), SourceLoc(),
                                            C.Id_LocalStorage, SourceLoc(),
                                            /*GenericParams=*/nullptr,
                                            actorDecl);
    aliasDecl->setUnderlyingType(localStorageType);
    aliasDecl->copyFormalAccessFrom(actorDecl, /*sourceIsParentContext=*/true);

    aliasDecl->dump();
    fprintf(stderr, "[%s:%d] (%s) ALIAS\n", __FILE__, __LINE__, __FUNCTION__);
    actorDecl->addMember(aliasDecl);
  }
}

/******************************************************************************/
/******************************* INITIALIZERS *********************************/
/******************************************************************************/

// ==== Distributed Actor: Local Initializer -----------------------------------

/// Creates a new \c CallExpr representing
///
///     transport.assignAddress(Self.self)
///
/// \param C The AST context to create the expression in.
/// \param DC The \c DeclContext to create any decls in.
/// \param base The base expression to make the call on.
/// \param returnType The return type of the call.
/// \param param The parameter to the call.
static CallExpr *
createCall_DistributedActor_transport_assignAddress(ASTContext &C,
                                 DeclContext *DC,
                                 Expr *base, Type returnType,
                                 Type param) {
  // (_ actorType:)
  auto *paramDecl = new (C) ParamDecl(SourceLoc(),
                                      SourceLoc(), Identifier(),
                                      SourceLoc(), C.Id_actorType, DC);
  paramDecl->setImplicit();
  paramDecl->setSpecifier(ParamSpecifier::Default);
  paramDecl->setInterfaceType(returnType);

  // transport.assignAddress(_:) expr
  auto *paramList = ParameterList::createWithoutLoc(paramDecl);
  auto *unboundCall = UnresolvedDotExpr::createImplicit(C, base,
                                                        C.Id_assignAddress,
                                                        paramList);

  // DC->mapTypeIntoContext(param->getInterfaceType());
  auto *selfTypeExpr = TypeExpr::createImplicit(param, C);
  auto *dotSelfTypeExpr = new (C) DotSelfExpr(selfTypeExpr, SourceLoc(),
                                              SourceLoc(), param);

  // Full bound self.assignAddress(Self.self) call
  Expr *args[1] = {dotSelfTypeExpr};
  Identifier argLabels[1] = {Identifier()};
  return CallExpr::createImplicit(C, unboundCall, C.AllocateCopy(args),
                                  C.AllocateCopy(argLabels));
}

/// Synthesizes the body of the `init(transport:)` initializer as:
///
/// ```
/// init(transport: ActorTransport)
///   self.actorTransport = transport
///   self.actorAddress = try transport.assignAddress(Self.self)
/// }
/// ```
///
/// \param initDecl The function decl whose body to synthesize.
static std::pair<BraceStmt *, bool>
createBody_DistributedActor_init_transport(AbstractFunctionDecl *initDecl, void *) {
  auto *funcDC = cast<DeclContext>(initDecl);
  auto DC = initDecl->getDeclContext();
  ASTContext &C = funcDC->getASTContext();

  SmallVector<ASTNode, 3> statements;

  auto transportParam = initDecl->getParameters()->get(0);
  auto *transportExpr = new (C) DeclRefExpr(ConcreteDeclRef(transportParam),
                                            DeclNameLoc(), /*Implicit=*/true);

  auto *selfRef = DerivedConformance::createSelfDeclRef(initDecl);
  auto selfType = funcDC->getInnermostTypeContext()->getSelfTypeInContext();

  // ==== `self.actorTransport = transport`
  {
    auto *varTransportExpr = UnresolvedDotExpr::createImplicit(C, selfRef,
                                                               C.Id_actorTransport);
    auto *assignTransportExpr = new (C) AssignExpr(
        varTransportExpr, SourceLoc(), transportExpr, /*Implicit=*/true);
    // assignTransportExpr->setType(TupleType::getEmpty(C));
    statements.push_back(assignTransportExpr);
  }

  // ==== `self.actorAddress = transport.assignAddress<Self>(Self.self)`
  {
    // self.actorAddress
    auto *varAddressExpr = UnresolvedDotExpr::createImplicit(C, selfRef,
                                                             C.Id_actorAddress);
    // Bound transport.assignAddress(Self.self) call
    auto addressType = C.getActorAddressDecl()->getDeclaredInterfaceType();
    auto *callExpr = createCall_DistributedActor_transport_assignAddress(C, funcDC,
        /*base=*/transportExpr,
        /*returnType=*/addressType,
        /*param=*/selfType);
    auto *assignAddressExpr = new (C) AssignExpr(
        varAddressExpr, SourceLoc(), callExpr, /*Implicit=*/true);
    // assignAddressExpr->setType(TupleType::getEmpty(C));
    statements.push_back(assignAddressExpr);
  }

  // ==== `self.storage = .local($Instance(...))`
//  {
//    // self.storage
//    auto *varStorageExpr = UnresolvedDotExpr::createImplicit(C, selfRef,
//                                                             C.Id_storage); // TODO: $storage
//
//    // DistributedActorStorage<?>
//    auto storageTypeDecl = C.getDistributedActorStorageDecl();
//
////    // user storage type: DistributedActorPersonality<DistributedActorLocalStorage>
////    auto selfClassDecl = dyn_cast<ClassDecl>(initDecl->getParent());
////    auto localStorageTypeDecls = selfClassDecl->lookupDirect(DeclName(C.Id_DistributedActorLocalStorage));
////    if (localStorageTypeDecls.size() > 1) {
////      assert(false && "Only a single DistributedActorLocalStorage type may be declared!");
////    }
////    TypeDecl *localStorageTypeDecl = dyn_cast<TypeDecl>(localStorageTypeDecls.front());
////    if (!localStorageTypeDecl) {
////      // TODO: diagnose here
////      assert(false && "could not find DistributedActorLocalStorage in distributed actor");
////    }
////
////    auto localStorageType = localStorageTypeDecl->getDeclaredInterfaceType();
//////    if (isa<TypeAliasDecl>(localStorageType)) // TODO: doug, ??????
//////      localStorageType = localStorageType->getAnyNominal();
//
//    auto classDecl = dyn_cast<ClassDecl>(initDecl->getParent());
//
//    fprintf(stderr, "\n");
//    classDecl->dump();
//    fprintf(stderr, "[%s:%d] (%s) PARENT ^^^^\n", __FILE__, __LINE__, __FUNCTION__);
//
//    auto boundStorageType = getBoundPersonalityStorageType(C, classDecl);
//    auto *boundStorageDecl = boundStorageType->getDecl();
//    fprintf(stderr, "\n");
////    boundStorageType->dump();
//    boundStorageDecl->dump();
//    fprintf(stderr, "[%s:%d] (%s) boundStorageType ^^^^\n", __FILE__, __LINE__, __FUNCTION__);
////    auto boundStorageTypeExpr = TypeExpr::createImplicit(boundStorageType, C);
////    fprintf(stderr, "\n");
////    boundStorageTypeExpr->dump();
////    fprintf(stderr, "[%s:%d] (%s) boundStorageTypeExpr ^^^^\n", __FILE__, __LINE__, __FUNCTION__);
////    auto storageTypeSelfRef = new (C) DotSelfExpr(
////        boundStorageTypeExpr, SourceLoc(), SourceLoc());
////    auto localStorageExpr =
////        UnresolvedDotExpr::createImplicit(C, boundStorageDecl, C.Id_remote); // TODO: this should store the local thing
//    auto localStorageExpr =
//        UnresolvedDotExpr::createImplicit(
//            C,
//            new (C) DeclRefExpr(ConcreteDeclRef(boundStorageDecl), DeclNameLoc(), /*Implicit=*/true),
//            C.Id_remote); // TODO: this should store the local thing
//
//    fprintf(stderr, "\n");
//    localStorageExpr->dump();
//    fprintf(stderr, "[%s:%d] (%s) localStorageExpr ^^^^\n", __FILE__, __LINE__, __FUNCTION__);
//
//    auto *assignStorageExpr = new(C) AssignExpr(
//        varStorageExpr, SourceLoc(), localStorageExpr, /*Implicit=*/true);
//
//    fprintf(stderr, "\n");
//    assignStorageExpr->dump();
//    fprintf(stderr, "[%s:%d] (%s) assignStorageExpr ^^^^\n", __FILE__, __LINE__, __FUNCTION__);
//    // varStorageExpr->setType(TupleType::getEmpty(C));
//
//    assignStorageExpr->dump();
//    fprintf(stderr, "[%s:%d] (%s) ^^^^ THE ASSIGN STORAGE\n", __FILE__, __LINE__, __FUNCTION__);
//    statements.push_back(assignStorageExpr);
//  }

  auto *body = BraceStmt::create(C, SourceLoc(), statements, SourceLoc(),
      /*implicit=*/true);

  return { body, /*isTypeChecked=*/false };
}

/// Synthesizes the
///
/// ```
/// init(transport: ActorTransport)
/// ```
///
/// local initializer.
static ConstructorDecl *
createDistributedActor_init_local(ClassDecl *classDecl,
                                  ASTContext &ctx) {
  auto &C = ctx;
//  auto conformanceDC = derived.getConformanceContext();
  auto conformanceDC = classDecl;

  // Expected type: (Self) -> (ActorTransport) -> (Self)
  //
  // Params: (transport transport: ActorTransport)
  auto transportType = C.getActorTransportDecl()->getDeclaredInterfaceType();
  auto *transportParamDecl = new (C) ParamDecl(
      SourceLoc(), SourceLoc(), C.Id_transport,
      SourceLoc(), C.Id_transport, conformanceDC);
  transportParamDecl->setImplicit();
  transportParamDecl->setSpecifier(ParamSpecifier::Default);
  transportParamDecl->setInterfaceType(transportType);

  auto *paramList = ParameterList::createWithoutLoc(transportParamDecl);

  // Func name: init(transport:)
  DeclName name(C, DeclBaseName::createConstructor(), paramList);

  auto *initDecl =
      new (C) ConstructorDecl(name, SourceLoc(),
          /*Failable=*/false, SourceLoc(),
          /*Throws=*/false, SourceLoc(), paramList, // TODO: make it throws?
          /*GenericParams=*/nullptr, conformanceDC);
  initDecl->setImplicit();
  initDecl->setSynthesized();
  initDecl->setBodySynthesizer(&createBody_DistributedActor_init_transport);

  // This constructor is 'required', all distributed actors MUST have it.
  auto *reqAttr = new (C) RequiredAttr(/*IsImplicit*/true);
  initDecl->getAttrs().add(reqAttr);

  initDecl->copyFormalAccessFrom(classDecl, /*sourceIsParentContext=*/true);

  fprintf(stderr, "\n", __FILE__, __LINE__, __FUNCTION__);
  initDecl->dump();
  fprintf(stderr, "[%s:%d] (%s) SYNTHESIZED INIT LOCAL\n", __FILE__, __LINE__, __FUNCTION__);

  return initDecl;
}

// ==== Distributed Actor: Resolve Initializer ---------------------------------


/// Creates a new \c CallExpr representing
///
///     transport.resolve(address: address, as: Self.self)
///
static CallExpr *
createCall_DistributedActor_transport_resolve(
    ASTContext &C, DeclContext *DC,
    Expr *base, Type addressType,
    DeclRefExpr *paramAddress, // FIXME???
    Type paramSelfType
) {
  // (address:)
  auto *paramAddressDecl = new (C) ParamDecl(
      SourceLoc(), SourceLoc(), C.Id_address, SourceLoc(), C.Id_address, DC);
  paramAddressDecl->setImplicit();
  paramAddressDecl->setSpecifier(ParamSpecifier::Default);
  paramAddressDecl->setInterfaceType(addressType);

  // (as selfType:)
  auto *paramSelfTypeDecl = new (C) ParamDecl(
      SourceLoc(), SourceLoc(), C.Id_as, SourceLoc(), C.Id_actorType, DC);
  paramSelfTypeDecl->setImplicit();
  paramSelfTypeDecl->setSpecifier(ParamSpecifier::Default);
  paramSelfTypeDecl->setInterfaceType(addressType);

  // (address:as:)
  auto *paramList = ParameterList::create(
      C,
      /*LParenLoc=*/SourceLoc(),
      /*params=*/{paramAddressDecl, paramSelfTypeDecl},
      /*RParenLoc=*/SourceLoc()
  );

  // transport.assignAddress(address:as:) expr
  auto *unboundCall = UnresolvedDotExpr::createImplicit(
      C, base, C.Id_resolve, paramList);

  // DC->mapTypeIntoContext(param->getInterfaceType());
  auto *selfTypeExpr = TypeExpr::createImplicit(paramSelfType, C);
  auto *dotSelfTypeExpr = new (C) DotSelfExpr(
      selfTypeExpr, SourceLoc(), SourceLoc(), paramSelfType);

  // Full bound self.resolve(address: address, as: Self.self) call
  Expr *args[2] = {paramAddress, dotSelfTypeExpr};
  Identifier argLabels[2] = {C.Id_address, C.Id_as};
  return CallExpr::createImplicit(
      C, unboundCall, C.AllocateCopy(args), C.AllocateCopy(argLabels));
}

///// Creates a new VarDecl for:
/////
/////     let resolved: ResolvedDistributedActor<Act>
/////
//static VarDecl*
//createVar_resolved(ASTContext &C, DeclContext *DC,
//                   NominalTypeDecl *resolvedTypeDecl,
//                   Type selfType,
//                   VarDecl::Introducer introducer) {
//  // Bind ResolvedDistributedActor to ResolvedDistributedActor<Act>
//  Type boundType[1] = {selfType};
//  auto resolvedType = BoundGenericType::get(resolvedTypeDecl, Type(),
//                                            C.AllocateCopy(boundType));
//
//  // let resolved : ResolvedDistributedActor<Act>
//  auto *resolvedDecl = new (C) VarDecl(/*IsStatic=*/false, introducer,
//                                                    SourceLoc(), C.Id_resolved, DC);
//  resolvedDecl->setImplicit();
//  resolvedDecl->setSynthesized();
//  resolvedDecl->setInterfaceType(resolvedType);
//  return resolvedDecl;
//}

static CallExpr *
createCall_DistributedActor_createProxy(ASTContext &C,
                                        DeclContext *DC,
                                        Type paramActorType) {
  // (_ actorType:)
  auto *paramDecl = new (C) ParamDecl(SourceLoc(),
                                      SourceLoc(), Identifier(),
                                      SourceLoc(), C.Id_actorType, DC);
  paramDecl->setImplicit();
  paramDecl->setSpecifier(ParamSpecifier::Default);
  paramDecl->setInterfaceType(paramActorType); // FIXME: Any?

  // _createDistributedActorProxy(_:) expr
  auto *paramList = ParameterList::createWithoutLoc(paramDecl);
//  auto *unboundCall = UnresolvedDotExpr::createImplicit(C, /*base*/nullptr,
//                                                        C.Id_createDistributedActorProxy,
//                                                        paramList);
  auto *createDeclRef = UnresolvedDeclRefExpr::createImplicit(
      C, C.getIdentifier("_createDistributedActorProxy"));
//  createDeclRef->setType(paramActorType);

//   DC->mapTypeIntoContext(paramActorType->getInterfaceType());
  auto *actorTypeExpr = TypeExpr::createImplicit(paramActorType, C);
  auto *dotActorTypeExpr = new (C) DotSelfExpr(actorTypeExpr, SourceLoc(),
                                               SourceLoc(), paramActorType);

  // Full bound _createDistributedActorProxy(Self.self) call
  return CallExpr::createImplicit(
      C, createDeclRef,
      {dotActorTypeExpr},
      {Identifier()});

//  auto Call = CallExpr::createImplicit(C, createDeclRef, {}, {});
//  Call->setType(paramActorType);
//  return Call;
//  return CallExpr::create(C, createDeclRef, {}, {}, {}, false, false, actorType);
}

//static SwitchStmt*
//createSwitch_resolved(ASTContext &C, DeclContext *DC,
//                      Type resolvedEnumType,
//                      BraceStmt resolvedBody, BraceStmt makeProxyBody,
//                      Expr paramResolved) {
//  // prepare the cases for the switch with their appropriate bodies
//  SmallVector<ASTNode, 2> cases;
//
//  // ==== case .makeProxy:
//  {
//    EnumElementDecl* elt =
//
//    auto pat = new(C) EnumElementPattern(
//        TypeExpr::createImplicit(resolvedEnumType, C), SourceLoc(),
//        DeclNameLoc(), DeclNameRef(), elt, subpattern);
//    pat->setImplicit();
//
//    auto labelItem = CaseLabelItem(pat);
//    auto body = resolvedBody;
//    auto caseStmt = CaseStmt::create(
//        C, CaseParentKind::Switch, SourceLoc(),
//        labelItem, SourceLoc(), SourceLoc(), body,
//        /*case body vardecls*/ caseBodyVarDecls);
//    cases.push_back(caseStmt);
//  }
//
//  // ==== case .proxy:
//  {
//    // .<elt>(let a0, let a1, ...)
//    SmallVector < VarDecl * , 1 > payloadVars;
//    auto subpattern = DerivedConformance::enumElementPayloadSubpattern(
//        elt, 'a', encodeDecl, payloadVars, /* useLabels */ true);
//
//    // auto hasBoundDecls = !payloadVars.empty();
//    assert(payloadVars.size() == 1 && "Expected *1* bound decl for case .resolved(let instance)");
//    Optional <MutableArrayRef<VarDecl *>> caseBodyVarDecls;
//    // We allocated a direct copy of our var decls for the case
//    // body.
//    auto copy = C.Allocate<VarDecl *>(payloadVars.size());
//    for (unsigned i : indices(payloadVars)) {
//      auto *vOld = payloadVars[i];
//      auto *vNew = new(C) VarDecl(
//          /*IsStatic*/ false, vOld->getIntroducer(), vOld->getNameLoc(),
//                       vOld->getName(), vOld->getDeclContext());
//      vNew->setImplicit();
//      copy[i] = vNew;
//    }
//    caseBodyVarDecls.emplace(copy);
//  }
//
//  // ==== switch resolved { ... }
//  auto switchStmt = SwitchStmt::create(LabeledStmtInfo(), SourceLoc(), enumRef,
//                                       SourceLoc(), cases, SourceLoc(), C);
//  return switchStmt;
//}

/// Synthesizes the body for
///
/// ```
/// init(resolve address: ActorAddress, using transport: ActorTransport) throws {
///   switch try transport.resolve(address: address, as: Self.self) {
///   case .instance(let instance):
///     self = instance
///   case .makeProxy:
///     self = <<MAGIC MAKE PROXY>>(address, transport) // TODO: implement this
///   }
/// }
/// ```
///
/// \param initDecl The function decl whose body to synthesize.
static std::pair<BraceStmt *, bool>
createDistributedActor_init_resolve_body(AbstractFunctionDecl *initDecl, void *) {

  auto *funcDC = cast<DeclContext>(initDecl);
  auto &C = funcDC->getASTContext();

  SmallVector<ASTNode, 2> statements; // TODO: how many?

  auto selfType = funcDC->getInnermostTypeContext()->getSelfTypeInContext();
  auto *selfRef = DerivedConformance::createSelfDeclRef(initDecl);
  auto selfTypeExpr = new (C) DotSelfExpr(selfRef, SourceLoc(), SourceLoc());

  auto addressParam = initDecl->getParameters()->get(0);
  auto *addressExpr = new (C) DeclRefExpr(ConcreteDeclRef(addressParam),
                                          DeclNameLoc(), /*Implicit=*/true);

  auto transportParam = initDecl->getParameters()->get(1);
  auto *transportExpr = new (C) DeclRefExpr(ConcreteDeclRef(transportParam),
                                            DeclNameLoc(), /*Implicit=*/true);

  // ==== `self.actorAddress = address`
  auto *varAddressExpr = UnresolvedDotExpr::createImplicit(C, selfRef,
                                                             C.Id_actorAddress);
  auto *assignAddressExpr = new (C) AssignExpr(
      varAddressExpr, SourceLoc(), addressExpr, /*Implicit=*/true);
  assignAddressExpr->setType(TupleType::getEmpty(C));
  statements.push_back(assignAddressExpr);

  // ==== `self.actorTransport = transport`
  auto *varTransportExpr = UnresolvedDotExpr::createImplicit(C, selfRef,
                                                             C.Id_actorTransport);
  auto *assignTransportExpr = new (C) AssignExpr(
      varTransportExpr, SourceLoc(), transportExpr, /*Implicit=*/true);
  assignTransportExpr->setType(TupleType::getEmpty(C));
  statements.push_back(assignTransportExpr);


  // ==== ----------------------------------------------------
  // ==== `self = _createDistributedActorProxy(Self.self)

//  auto makeProxyCallExpr = createCall_DistributedActor_createProxy(
//      C, funcDC, selfType);

//  auto selfRef = DerivedConformance::createSelfDeclRef(toRawDecl);
//  auto bareTypeExpr = TypeExpr::createImplicit(rawTy, C);
//  auto typeExpr = new (C) DotSelfExpr(bareTypeExpr, SourceLoc(), SourceLoc());
//
//  auto makeProxyCallExpr = createCall_DistributedActor_createProxy(
//      C, funcDC, selfType);
//
//  auto castProxyExpr = ForcedCheckedCastExpr::createImplicit(
//      C, makeProxyCallExpr, selfType);
//  castProxyExpr->setCastKind(CheckedCastKind::ValueCast);

//  auto castProxyExpr = UnresolvedDeclRefExpr::createImplicit(
//      C, C.getIdentifier("unsafeBitCast"), {Identifier(), C.Id_to});
//  auto call = CallExpr::createImplicit(
//      C, castProxyExpr,
//      {makeProxyCallExpr, selfTypeExpr},
//      {Identifier(), C.Id_to});

//  auto *assignSelfProxyExpr = new (C) AssignExpr(
//      selfRef, SourceLoc(), makeProxyCallExpr, /*Implicit=*/true);
//  statements.push_back(assignSelfProxyExpr);
  // ==== ----------------------------------------------------

//  // ==== ----------------------------------------------------
//  // ==== `self.actorTransport = transport`
//  auto *varTransportExpr = UnresolvedDotExpr::createImplicit(C, selfRef,
//                                                             C.Id_actorTransport);
//  auto *assignTransportExpr = new (C) AssignExpr(
//      varTransportExpr, SourceLoc(), transportExpr, /*Implicit=*/true);
//  statements.push_back(assignTransportExpr);
//
//  // ==== `self.actorAddress = transport.assignAddress<Self>(Self.self)`
//  // self.actorAddress
//  auto *varAddressExpr = UnresolvedDotExpr::createImplicit(C, selfRef,
//                                                           C.Id_actorAddress);
//  // Bound transport.assignAddress(Self.self) call
//  auto addressType = C.getActorAddressDecl()->getDeclaredInterfaceType();
//  auto selfType = funcDC->getInnermostTypeContext()->getSelfTypeInContext();
//  auto *callExpr = createCall_DistributedActor_transport_assignAddress(C, funcDC,
//      /*base=*/transportExpr,
//      /*returnType=*/addressType,
//      /*param=*/selfType);
//  auto *assignAddressExpr = new (C) AssignExpr(
//      varAddressExpr, SourceLoc(), callExpr, /*Implicit=*/true);
//  statements.push_back(assignAddressExpr);
//  // ==== ----------------------------------------------------

  // ==== ----------------------------------------------------
  // ==== ----------------------------------------------------
  // TODO: towards this one...
  // FIXME: this must be checking with the transport instead
  // ==== TODO: let result = try transport.resolve(address: address, as: selfType)
  // ==== TODO: switch result {
  // ==== TODO: case .resolved(let instance):
  // ==== TODO:   self = instance
  // ==== TODO: case .makeProxy:
//  // ==== try transport.resolve(address
//  auto resolvedType = C.getResolvedDistributedActorDecl()->getDeclaredInterfaceType();
//  auto selfType = funcDC->getInnermostTypeContext()->getSelfTypeInContext();
//  auto *resolveCallExpr = createCall_DistributedActor_transport_resolve(C, funcDC,
//      /*base=*/transportExpr,
//      /*resolvedType=*/resolvedType,
//      /*paramAddress=*/addressExpr,
//      /*paramSelfType=*/selfType);
//  auto *tryResolveCallExpr = new (C) TryExpr(SourceLoc(), resolveCallExpr, Type(),
//      /*Implicit=*/true);
//
//  // TODO: check the call result, is it a resolved or instance
//  // let resolved: ResolvedDistributedActor<Act>
////  VarDecl *resolvedDecl = createVar_resolved(
////      C, funcDC, resolvedDecl, selfType, VarDecl::Introducer::Let);
////  auto *resolvedPattern = NamedPattern::createImplicit(C, resolvedDecl);
////  auto *resolvedBindingDecl = PatternBindingDecl::createImplicit(
////      C, StaticSpellingKind::None, resolvedPattern, resolveCallExpr, funcDC);
////  statements.push_back(resolvedDecl);
//
//  // TODO apply?
//
//  // ==== body for `case .resolved(let instance): ...`
//  SmallVector<ASTNode, 2> caseStatements;
//  auto resolvedInstanceCaseBody = BraceStmt::create(C, SourceLoc(), caseStatements, SourceLoc());
//  // body for `case .makeProxy: ...
//  auto makeProxyCaseBody = BraceStmt::create(C, SourceLoc(), caseStatements, SourceLoc());
//
//  // ==== switch resolved { ... }
//  auto *resolvedSwitchDecl = createSwitch_resolved(
//      C, funcDC,
//      resolvedType,
//      /*case resolved: {body}*/resolvedInstanceCaseBody,
//      /*case makeProxy: {body}*/makeProxyCaseBody,
//      /*paramResolved=*/resolvedDecl);
//  statements.push_back(resolvedSwitchDecl);
//
  // ==== ----------------------------------------------------
  // ==== ----------------------------------------------------

  auto *body = BraceStmt::create(C, SourceLoc(), statements, SourceLoc(),
      /*implicit=*/true);

//
//  body->dump();
//  fprintf(stderr, "[%s:%d] (%s) SYNTHESIZED CONSTRUCTOR ^^^\n", __FILE__, __LINE__, __FUNCTION__);
  return { body, /*isTypeChecked=*/false };
}

/// Synthesizes the
///
/// ```
/// init(resolve address: ActorAddress, using transport: ActorTransport) throws
/// ```
///
/// resolve initializer.
static ConstructorDecl *
createDistributedActor_init_resolve(ClassDecl *classDecl,
                                    ASTContext &ctx) {
  auto &C = ctx;

  auto conformanceDC = classDecl;

  // Expected type: (Self) -> (ActorAddress, ActorTransport) -> (Self)
  //
  // Param: (resolve address: ActorAddress)
  auto addressType = C.getActorAddressDecl()->getDeclaredInterfaceType();
  auto *addressParamDecl = new (C) ParamDecl(
      SourceLoc(), SourceLoc(), C.Id_resolve,
      SourceLoc(), C.Id_address, conformanceDC);
  addressParamDecl->setImplicit();
  addressParamDecl->setSpecifier(ParamSpecifier::Default);
  addressParamDecl->setInterfaceType(addressType);

  // Param: (using transport: ActorTransport)
  auto transportType = C.getActorTransportDecl()->getDeclaredInterfaceType();
  auto *transportParamDecl = new (C) ParamDecl(
      SourceLoc(), SourceLoc(), C.Id_using,
      SourceLoc(), C.Id_transport, conformanceDC);
  transportParamDecl->setImplicit();
  transportParamDecl->setSpecifier(ParamSpecifier::Default);
  transportParamDecl->setInterfaceType(transportType);

  auto *paramList = ParameterList::create(
      C,
      /*LParenLoc=*/SourceLoc(),
      /*params=*/{addressParamDecl, transportParamDecl},
      /*RParenLoc=*/SourceLoc()
  );

  // Func name: init(resolve:using:)
  DeclName name(C, DeclBaseName::createConstructor(), paramList);

  auto *initDecl =
      new (C) ConstructorDecl(name, SourceLoc(),
          /*Failable=*/false, SourceLoc(),
          /*Throws=*/true, SourceLoc(), paramList,
          /*GenericParams=*/nullptr, conformanceDC);
  initDecl->setImplicit();
  initDecl->setSynthesized();
  // initDecl->setBodySynthesizer(&createDistributedActor_init_resolve_body); // FIXME?????!!!!!! !!!!!!
  initDecl->setBodySynthesizer(synthesizeStubBody);
//  initDecl->setStubImplementation(true); // TODO: if we set this we're not getting into SIL generation for it?

  // This constructor is 'required', all distributed actors MUST have it.
  initDecl->getAttrs().add(new (C) RequiredAttr(/*IsImplicit*/true));

  initDecl->copyFormalAccessFrom(classDecl, /*sourceIsParentContext=*/true);

  fprintf(stderr, "\n", __FILE__, __LINE__, __FUNCTION__);
  initDecl->dump();
  fprintf(stderr, "[%s:%d] (%s) SYNTHESIZED INIT RESOLVE\n", __FILE__, __LINE__, __FUNCTION__);

  return initDecl;
}

/// Detects which initializer to create, and does so.
static ConstructorDecl *
createDistributedActorInit(ClassDecl *classDecl,
                           ConstructorDecl *requirement,
                           ASTContext &ctx) {
  assert(classDecl->isDistributedActor());

  auto &C = ctx;
  const auto name = requirement->getName();
  auto argumentNames = name.getArgumentNames();

  switch (argumentNames.size()) {
    case 1: {
      if (requirement->isDistributedActorLocalInit())
        return createDistributedActor_init_local(classDecl, ctx);
      break;
    }
    case 2: {
      if (requirement->isDistributedActorResolveInit())
        return createDistributedActor_init_resolve(classDecl, ctx);
      break;
    }
  }

  return nullptr;
}

static void collectNonOveriddenDistributedActorInits(
    ASTContext& Context,
    ClassDecl *actorDecl,
    SmallVectorImpl<ConstructorDecl *> &results) {
  assert(actorDecl->isDistributedActor());
  auto protoDecl = Context.getProtocol(KnownProtocolKind::DistributedActor);

//  // Record all of the initializers the actorDecl has implemented.
//  llvm::SmallPtrSet<ConstructorDecl *, 4> overriddenInits;
//  for (auto member : actorDecl->getMembers())
//    if (auto ctor = dyn_cast<ConstructorDecl>(member))
//      if (!ctor->hasStubImplementation())
//         // if (auto overridden = ctor->getOverriddenDecl())
//          overriddenInits.insert(ctor);
//
//  actorDecl->synthesizeSemanticMembersIfNeeded(
//    DeclBaseName::createConstructor());

  NLOptions subOptions = (NL_QualifiedDefault | NL_IgnoreAccessControl);
  SmallVector<ValueDecl *, 4> lookupResults;
  actorDecl->lookupQualified(
      protoDecl, DeclNameRef::createConstructor(),
      subOptions, lookupResults);

  for (auto decl : lookupResults) {
    // Distributed Actor Constructor
    auto daCtor = cast<ConstructorDecl>(decl);

//    // Skip invalid superclass initializers.
//    if (daCtor->isInvalid())
//      continue;
//
//    // Skip unavailable superclass initializers.
//    if (AvailableAttr::isUnavailable(daCtor))
//      continue;
//
// TODO: Don't require it if overriden
//    if (!overriddenInits.count(daCtor))
    results.push_back(daCtor);
  }
}


/// For a distributed actor, automatically define initializers
/// that match the DistributedActor requirements.
// TODO: inheritance is tricky here?
static void addImplicitDistributedActorConstructors(ClassDecl *decl) {
  fprintf(stderr, "[%s:%d] (%s) SYNTHESIZE CONSTRUCTORS\n", __FILE__, __LINE__, __FUNCTION__);
  // Bail out if not a distributed actor definition.
  if (!decl->isDistributedActor())
    return;

  for (auto member : decl->getMembers()) {
    if (auto ctor = dyn_cast<ConstructorDecl>(member)) {
      if (ctor->isRecursiveValidation())
        return;
    }
  }

  decl->setAddedImplicitInitializers();

  // Check whether the user has defined a designated initializer for this class,
  // and whether all of its stored properties have initial values.
  auto &ctx = decl->getASTContext();
//  bool foundDesignatedInit = hasUserDefinedDesignatedInit(ctx.evaluator, decl);
//  bool defaultInitable =
//      areAllStoredPropertiesDefaultInitializable(ctx.evaluator, decl);
//
//  // We can't define these overrides if we have any uninitialized
//  // stored properties.
//  if (!defaultInitable && !foundDesignatedInit)
//    return;

  SmallVector<ConstructorDecl *, 4> nonOverridenCtors;
  collectNonOveriddenDistributedActorInits(
      ctx, decl, nonOverridenCtors);

  // FIXME: change this, as people cannot ever override our inits anyway
  for (auto *daCtor : nonOverridenCtors) {
    if (auto ctor = createDistributedActorInit(decl, daCtor, ctx)) {
      decl->addMember(ctor);
    }
  }
}

/******************************************************************************/
/******************************** PROPERTIES **********************************/
/******************************************************************************/

// TODO: deduplicate with 'declareDerivedProperty' from DerivedConformance...
std::pair<VarDecl *, PatternBindingDecl *>
createStoredProperty(ValueDecl *parent, DeclContext *parentDC, ASTContext &ctx,
                     VarDecl::Introducer introducer, Identifier name,
                     Type propertyInterfaceType, Type propertyContextType,
                     bool isStatic, bool isFinal,
                     llvm::Optional<AccessLevel> accessLevel = llvm::None) {
  VarDecl *propDecl = new (ctx) VarDecl(
      /*IsStatic*/ isStatic, introducer, SourceLoc(), name, parentDC);
  propDecl->setImplicit();
  propDecl->setSynthesized();
  if (accessLevel.hasValue()) {
    propDecl->setAccess(accessLevel.getValue());
  } else {
    propDecl->copyFormalAccessFrom(parent, /*sourceIsParentContext*/ true);
  }
  propDecl->setInterfaceType(propertyInterfaceType);

  Pattern *propPat = NamedPattern::createImplicit(ctx, propDecl);
  propPat->setType(propertyContextType);

  propPat = TypedPattern::createImplicit(ctx, propPat, propertyContextType);
  propPat->setType(propertyContextType);

  auto *pbDecl = PatternBindingDecl::createImplicit(
      ctx, StaticSpellingKind::None, propPat, /*InitExpr*/ nullptr,
      parentDC);
  return {propDecl, pbDecl};
}

/// Adds the following, fairly special, properties to each distributed actor:
/// - actorTransport
/// - actorAddress
/// - storage
static void addImplicitDistributedActorStoredProperties(ClassDecl *actorDecl) {
  fprintf(stderr, "\n");
  actorDecl->dump();
  fprintf(stderr, "[%s:%d] (%s) SYNTH PROPERTIES FOR ^^^^\n", __FILE__, __LINE__, __FUNCTION__);

  assert(actorDecl->isDistributedActor());
  auto &C = actorDecl->getASTContext();

  // ```
  // @_distributedActorIndependent
  // let actorAddress: ActorAddress
  // ```
  // (no need for @actorIndependent because it is an immutable let)
  {
    auto propertyType = C.getActorAddressDecl()->getDeclaredInterfaceType();

    VarDecl *propDecl;
    PatternBindingDecl *pbDecl;
    std::tie(propDecl, pbDecl) = createStoredProperty(
        actorDecl, actorDecl, C,
        VarDecl::Introducer::Let, C.Id_actorAddress,
        propertyType, propertyType,
        /*isStatic=*/false, /*isFinal=*/true);

    // mark as @_distributedActorIndependent, allowing access to it from everywhere
    propDecl->getAttrs().add(
        new (C) DistributedActorIndependentAttr(/*IsImplicit=*/true));

    actorDecl->addMember(propDecl);
    actorDecl->addMember(pbDecl);
  }

  // ```
  // @_distributedActorIndependent
  // let actorTransport: ActorTransport
  // ```
  // (no need for @actorIndependent because it is an immutable let)
  {
    auto propertyType = C.getActorTransportDecl()->getDeclaredInterfaceType();

    VarDecl *propDecl;
    PatternBindingDecl *pbDecl;
    std::tie(propDecl, pbDecl) = createStoredProperty(
        actorDecl, actorDecl, C,
        VarDecl::Introducer::Let, C.Id_actorTransport,
        propertyType, propertyType,
        /*isStatic=*/false, /*isFinal=*/true);

    // mark as @_distributedActorIndependent, allowing access to it from everywhere
    propDecl->getAttrs().add(
        new (C) DistributedActorIndependentAttr(/*IsImplicit=*/true));

    actorDecl->addMember(propDecl);
    actorDecl->addMember(pbDecl);
  }

//  // ```
//  // private var storage: DistributedActorStorage<LocalStorage>
//  // ```
//  {
//    auto boundPersonalityType = getBoundPersonalityStorageType(C, actorDecl);
//
//    VarDecl *propDecl;
//    PatternBindingDecl *pbDecl;
//    std::tie(propDecl, pbDecl) = createStoredProperty(
//        actorDecl, actorDecl, C,
//        VarDecl::Introducer::Let, C.Id_storage,
//        boundPersonalityType, boundPersonalityType,
//        /*isStatic=*/false, /*isFinal=*/false);
//
////    // Mark it private, only the actor itself can access storage.
////    propDecl->setAccess(AccessLevel::Private); // TODO: do this, but this fails on 'access already set' we must set this at creation inside the createStoredProperty
//
////    // FIXME: we need to somehow mark it to not be included in "slap property wrappers on things"
////    //       however independent is the wrong thing; so I guess just the synthesized or implicit thing?
////    // SEE ALSO: isDistributedActorStoredProperty which would be part of the fix
//    propDecl->getAttrs().add(
//        new (C) DistributedActorIndependentAttr(/*IsImplicit=*/true));
//
//    actorDecl->addMember(propDecl);
//    actorDecl->addMember(pbDecl);
//  }
}

/******************************************************************************/
/***************************** STORAGE STRUCT *********************************/
/******************************************************************************/

// TODO: similar to getVarNameForCoding, so maybe move it onto VarDecl
static Identifier getVarName(VarDecl *var) {
  if (auto originalVar = var->getOriginalWrappedProperty())
    return originalVar->getName();

  return var->getName();
}

/// Create a `$Storage` type that mirrors all stored properties of a distributed actor.
///
/// E.g. for the following distributed actor:

///     distributed actor Greeter {
///         var name: String
///     }
///
/// to be represented as:
///
///     distributed actor Greeter {
///       private Storage {
///         var name: String
///       }
///
///       @distributedActorState var name: String
///     }
///
/// Where the `distributedActorState` property wrapper is implemented as
static void addImplicitDistributedActorLocalStorageStruct(ClassDecl *actorDecl) {
  assert(actorDecl->isDistributedActor());
  auto &C = actorDecl->getASTContext();

  StructDecl *storageDecl = new (C) StructDecl(
      SourceLoc(), C.Id_DistributedActorLocalStorage, SourceLoc(),
      /*Inherited*/ {},
      /*GenericParams*/ {}, actorDecl
      );
  storageDecl->setImplicit();
//  storageDecl->setSynthesized();
  // storageDecl->setAccess(AccessLevel::Private); // TODO: would love for these to be private (!!!)
  storageDecl->copyFormalAccessFrom(actorDecl, /*sourceIsParentContext=*/true); // TODO: unfortunate
  // storageDecl->setUserAccessible(false); // TODO: would be nice

  // mirror all stored properties from the 'distributed actor' decl
  // to the storage struct.
  for (auto *varDecl : actorDecl->getStoredProperties()) {
    if (!varDecl->isUserAccessible())
      continue;

//    fprintf(stderr, "[%s:%d] (%s) mirror [%s] to DistributedActorLocalStorage.%s\n",
//            __FILE__, __LINE__, __FUNCTION__, varDecl->getBaseName(), varDecl->getBaseName());

    VarDecl *propDecl;
    PatternBindingDecl *pbDecl;
    auto propertyType = varDecl->getInterfaceType();
    std::tie(propDecl, pbDecl) = createStoredProperty(
        storageDecl, storageDecl, C,
        VarDecl::Introducer::Var, getVarName(varDecl), // TODO: copy whether it was a Var or a Let
        propertyType, propertyType,
        /*isStatic=*/false, /*isFinal=*/false); // TODO: if Let then make it final

    storageDecl->addMember(propDecl);
    storageDecl->addMember(pbDecl);
  }

  TypeChecker::checkConformancesInContext(storageDecl);

  storageDecl->dump();
  fprintf(stderr, "[%s:%d] (%s) synthesized STORAGE STRUCT\n", __FILE__, __LINE__, __FUNCTION__);
  actorDecl->addMember(storageDecl);
}

/******************************************************************************/
/************************ SYNTHESIS ENTRY POINT *******************************/
/******************************************************************************/

///// Entry point for adding all computed members to a distributed actor decl.
//static void addImplicitDistributedActorConstructors(ClassDecl *decl) {
//  // Bail out if not a distributed actor definition.
//  if (!decl->isDistributedActor())
//    return;
//
////  addImplicitDistributedActorLocalStorageStruct(decl);
//////  addImplicitDistributedActorTypeAliases(decl);
////  addImplicitDistributedActorStoredProperties(decl);
//  addImplicitDistributedActorConstructors(decl);
//
////  fprintf(stderr, "[%s:%d] (%s) ----- ENTIRE DIST DECL --------\n", __FILE__, __LINE__, __FUNCTION__);
////  decl->dump();
////  fprintf(stderr, "[%s:%d] (%s) ===== END OF DIST DECL ========\n", __FILE__, __LINE__, __FUNCTION__);
//}

//static void addImplicitDistributedActorStorage(ClassDecl *decl) {
//  // Bail out if not a distributed actor definition.
//  if (!decl->isDistributedActor())
//    return;
//
//  addImplicitDistributedActorLocalStorageStruct(decl);
////  addImplicitDistributedActorTypeAliases(decl);
//  addImplicitDistributedActorStoredProperties(decl);
//}
