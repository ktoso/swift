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
//
// This file implements semantic analysis for declarations.
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
/******************************* INITIALIZERS *********************************/
/******************************************************************************/

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
  ASTContext &C = funcDC->getASTContext();

  SmallVector<ASTNode, 2> statements;

  auto transportParam = initDecl->getParameters()->get(0);
  auto *transportExpr = new (C) DeclRefExpr(ConcreteDeclRef(transportParam),
                                            DeclNameLoc(), /*Implicit=*/true);

  auto *selfRef = DerivedConformance::createSelfDeclRef(initDecl);

  // ==== `self.actorTransport = transport`
  auto *varTransportExpr = UnresolvedDotExpr::createImplicit(C, selfRef,
                                                             C.Id_actorTransport);
  auto *assignTransportExpr = new (C) AssignExpr(
      varTransportExpr, SourceLoc(), transportExpr, /*Implicit=*/true);
  statements.push_back(assignTransportExpr);

  // ==== `self.actorAddress = transport.assignAddress<Self>(Self.self)`
  // self.actorAddress
  auto *varAddressExpr = UnresolvedDotExpr::createImplicit(C, selfRef,
                                                           C.Id_actorAddress);
  // Bound transport.assignAddress(Self.self) call
  auto addressType = C.getActorAddressDecl()->getDeclaredInterfaceType();
  auto selfType = funcDC->getInnermostTypeContext()->getSelfTypeInContext();
  auto *callExpr = createCall_DistributedActor_transport_assignAddress(C, funcDC,
      /*base=*/transportExpr,
      /*returnType=*/addressType,
      /*param=*/selfType);
  auto *assignAddressExpr = new (C) AssignExpr(
      varAddressExpr, SourceLoc(), callExpr, /*Implicit=*/true);
  statements.push_back(assignAddressExpr);

  auto *body = BraceStmt::create(C, SourceLoc(), statements, SourceLoc(),
      /*implicit=*/true);

  return { body, /*isTypeChecked=*/false };
}

/// Synthesizes the `init(transport: ActorTransport)` initializer.
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

  // This constructor is 'required', all distributed actors MUST invoke it.
  auto *reqAttr = new (C) RequiredAttr(/*IsImplicit*/true);
  initDecl->getAttrs().add(reqAttr);

//  // This constructor is 'required', all distributed actors MUST invoke it.
//  // TODO: this makes sense I guess, and we should ban defining such constructor at all.
//  auto *reqAttr = new (C) RequiredAttr(/*IsImplicit*/true);
//  initDecl->getAttrs().add(reqAttr);

  initDecl->copyFormalAccessFrom(classDecl, /*sourceIsParentContext=*/true);

//  fprintf(stderr, "[%s:%d] >> (%s) %s  \n", __FILE__, __LINE__, __FUNCTION__, "INIT DECL:");
//  initDecl->dump();

  return initDecl;
}

/// Synthesizes the body for
///
/// ```
/// init(resolve address: ActorAddress, using transport: ActorTransport) throws {
///   // TODO: implement calling the transport
///   switch try transport.resolve(address: address, as: Self.self) {
///   case .instance(let instance):
///     self = instance
///   case .makeProxy:
///   // TODO: use RebindSelfInConstructorExpr here?
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

  auto addressParam = initDecl->getParameters()->get(0);
  auto *addressExpr = new (C) DeclRefExpr(ConcreteDeclRef(addressParam),
                                          DeclNameLoc(), /*Implicit=*/true);

  auto transportParam = initDecl->getParameters()->get(1);
  auto *transportExpr = new (C) DeclRefExpr(ConcreteDeclRef(transportParam),
                                            DeclNameLoc(), /*Implicit=*/true);

  auto *selfRef = DerivedConformance::createSelfDeclRef(initDecl);

  // ==== `self.actorTransport = transport`
  auto *varTransportExpr = UnresolvedDotExpr::createImplicit(C, selfRef,
                                                             C.Id_actorTransport);
  auto *assignTransportExpr = new (C) AssignExpr(
      varTransportExpr, SourceLoc(), transportExpr, /*Implicit=*/true);
  statements.push_back(assignTransportExpr);

  // ==== `self.actorAddress = transport.assignAddress<Self>(Self.self)`
  // self.actorAddress
  auto *varAddressExpr = UnresolvedDotExpr::createImplicit(C, selfRef,
                                                           C.Id_actorAddress);
  // TODO implement calling the transport with the address and Self.self
  // FIXME: this must be checking with the transport instead
  auto *assignAddressExpr = new (C) AssignExpr(
      varAddressExpr, SourceLoc(), addressExpr, /*Implicit=*/true);
  statements.push_back(assignAddressExpr);
  // end-of-FIXME: this must be checking with the transport instead

  auto *body = BraceStmt::create(C, SourceLoc(), statements, SourceLoc(),
      /*implicit=*/true);

//  fprintf(stderr, "[%s:%d] >> (%s) %s  \n", __FILE__, __LINE__, __FUNCTION__, "INIT transport BODY:");
//  initDecl->dump();

  return { body, /*isTypeChecked=*/false };
}


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
//  fprintf(stderr, "[%s:%d] >> (%s) %s  \n", __FLE__, __LINE__, __FUNCTION__, "init func");
  DeclName name(C, DeclBaseName::createConstructor(), paramList);

  auto *initDecl =
      new (C) ConstructorDecl(name, SourceLoc(),
          /*Failable=*/false, SourceLoc(),
          /*Throws=*/false, SourceLoc(), paramList, // TODO: make throws.
          /*GenericParams=*/nullptr, conformanceDC);
  initDecl->setImplicit();
  initDecl->setSynthesized();
  initDecl->setBodySynthesizer(&createDistributedActor_init_resolve_body);
//  fprintf(stderr, "[%s:%d] >> (%s) %s  \n", __FILE__, __LINE__, __FUNCTION__, "init func prepared");

  // This constructor is 'required', all distributed actors MUST invoke it.
  auto *reqAttr = new (C) RequiredAttr(/*IsImplicit*/true);
  initDecl->getAttrs().add(reqAttr);

  initDecl->copyFormalAccessFrom(classDecl, /*sourceIsParentContext=*/true);

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

  if (argumentNames.size() == 1) {
    if (argumentNames[0] == C.Id_transport) {
      // TODO: check type
      return createDistributedActor_init_local(classDecl, ctx);
    }

    if (argumentNames[0] == C.Id_from) {
      // TODO: check type
      // TODO: implement synthesis
      requirement->dump();
      fprintf(stderr, "[%s:%d] >> (%s) %s \n", __FILE__, __LINE__, __FUNCTION__, "unrecognized constructor requirement for DistributedActor");

      return nullptr;
    }
  }

  if (argumentNames.size() == 2) {
    if (argumentNames[0] == C.Id_resolve &&
        argumentNames[1] == C.Id_using) {
      return createDistributedActor_init_resolve(classDecl, ctx);
    }
  }

  // TODO: synthesize

  requirement->dump();
  fprintf(stderr, "[%s:%d] >> (%s) %s \n", __FILE__, __LINE__, __FUNCTION__, "unrecognized constructor requirement for DistributedActor");
  return nullptr; // TODO: make it assert(false); after we're done with all
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


/// For a distributed actor class, automatically define initializers
/// that match the DistributedActor requirements.
// TODO: inheritance is tricky here?
static void addImplicitDistributedActorConstructors(ClassDecl *decl) {
  // Bail out if not a distributed actor definition.
  if (!decl->isDistributedActor())
    return;

  fprintf(stderr, "[%s:%d] >> (%s) %s  \n", __FILE__, __LINE__, __FUNCTION__, "GENERATE DA INITS");

  // Bail out if we're validating one of our constructors already;
  // we'll revisit the issue later.
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
createStoredProperty(ClassDecl *classDecl, ASTContext &ctx,
                     VarDecl::Introducer introducer, Identifier name,
                     Type propertyInterfaceType, Type propertyContextType,
                     bool isStatic, bool isFinal) {
  auto parentDC = classDecl;

  VarDecl *propDecl = new (ctx)
      VarDecl(/*IsStatic*/ isStatic, introducer,
                           SourceLoc(), name, parentDC);
  propDecl->setImplicit();
  propDecl->setSynthesized();
  propDecl->copyFormalAccessFrom(classDecl, /*sourceIsParentContext*/ true);
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
static void addImplicitDistributedActorStoredProperties(ClassDecl *decl) {
  assert(decl->isDistributedActor());

  auto &C = decl->getASTContext();

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
        decl, C,
        VarDecl::Introducer::Let, C.Id_actorAddress,
        propertyType, propertyType,
        /*isStatic=*/false, /*isFinal=*/true);

    // mark as @_distributedActorIndependent, allowing access to it from everywhere
    propDecl->getAttrs().add(new (C)
                                 DistributedActorIndependentAttr(/*IsImplicit=*/true));

    decl->addMember(propDecl);
    decl->addMember(pbDecl);
  }

  // ```
  // let actorTransport: ActorTransport
  // ```
  {
    auto propertyType = C.getActorTransportDecl()->getDeclaredInterfaceType();

    VarDecl *propDecl;
    PatternBindingDecl *pbDecl;
    std::tie(propDecl, pbDecl) = createStoredProperty(
        decl, C,
        VarDecl::Introducer::Let, C.Id_actorTransport,
        propertyType, propertyType,
        /*isStatic=*/false, /*isFinal=*/true);

    decl->addMember(propDecl);
    decl->addMember(pbDecl);
  }
}

/******************************************************************************/
/************************ SYNTHESIS ENTRY POINT *******************************/
/******************************************************************************/

/// Entry point for adding all computed members to a distributed actor decl.
static void addImplicitDistributedActorMembersToClass(ClassDecl *decl) {
  // Bail out if not a distributed actor definition.
  if (!decl->isDistributedActor())
    return;

  addImplicitDistributedActorConstructors(decl);
  addImplicitDistributedActorStoredProperties(decl);
}
