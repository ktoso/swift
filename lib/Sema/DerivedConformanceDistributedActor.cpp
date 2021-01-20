//===--- DerivedConformanceActor.cpp - Derived Actor Conformance ----------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
//
//  This file implements implicit derivation of the Actor protocol.
//
//===----------------------------------------------------------------------===//
#include "DerivedConformances.h"
#include "TypeChecker.h"
#include "TypeCheckConcurrency.h"
#include "swift/AST/NameLookupRequests.h"
#include "swift/AST/ParameterList.h"

using namespace swift;

bool DerivedConformance::canDeriveDistributedActor(
    NominalTypeDecl *nominal, DeclContext *dc) {
  auto classDecl = dyn_cast<ClassDecl>(nominal);
  return classDecl && classDecl->isDistributedActor() && dc == nominal;
}

//static DeclName getEnqueuePartialTaskName(ASTContext &ctx) {
//  return DeclName(ctx, ctx.Id_enqueue, { ctx.Id_partialTask });
//}
//
//static Type getPartialAsyncTaskType(ASTContext &ctx) {
//  auto concurrencyModule = ctx.getLoadedModule(ctx.Id_Concurrency);
//  if (!concurrencyModule)
//    return Type();
//
//  SmallVector<ValueDecl *, 2> decls;
//  concurrencyModule->lookupQualified(
//      concurrencyModule, DeclNameRef(ctx.Id_PartialAsyncTask),
//      NL_QualifiedDefault, decls);
//  for (auto decl : decls) {
//    if (auto typeDecl = dyn_cast<TypeDecl>(decl))
//      return typeDecl->getDeclaredInterfaceType();
//  }
//
//  return Type();
//}
//
///// Look for the default enqueue operation.
//static FuncDecl *getDefaultActorEnqueue(DeclContext *dc, SourceLoc loc) {
//  ASTContext &ctx = dc->getASTContext();
//  auto desc = UnqualifiedLookupDescriptor(
//      DeclNameRef(ctx.Id__defaultActorEnqueue),
//      dc, loc, UnqualifiedLookupOptions());
//  auto lookup =
//      evaluateOrDefault(ctx.evaluator, UnqualifiedLookupRequest{desc}, {});
//  for (const auto &result : lookup) {
//    // FIXME: Validate this further, because we're assuming the exact type.
//    if (auto func = dyn_cast<FuncDecl>(result.getValueDecl()))
//      return func;
//  }
//
//  return nullptr;
//}
//
//static std::pair<BraceStmt *, bool>
//deriveBodyActor_enqueuePartialTask(
//  AbstractFunctionDecl *enqueuePartialTask, void *) {
//  // func enqueue(partialTask: PartialAsyncTask) {
//  //   _defaultActorEnqueue(partialTask: partialTask, actor: self)
//  // }
//  ASTContext &ctx = enqueuePartialTask->getASTContext();
//  auto classDecl = enqueuePartialTask->getDeclContext()->getSelfClassDecl();
//
//  // Produce an empty brace statement on failure.
//  auto failure = [&]() -> std::pair<BraceStmt *, bool> {
//    auto body = BraceStmt::create(
//        ctx, SourceLoc(), { }, SourceLoc(), /*implicit=*/true);
//    return { body, /*isTypeChecked=*/true };
//  };
//
//  // Call into the runtime to enqueue the task.
//  auto fn = getDefaultActorEnqueue(classDecl, classDecl->getLoc());
//  if (!fn) {
//    classDecl->diagnose(
//        diag::concurrency_lib_missing, ctx.Id__defaultActorEnqueue.str());
//    return failure();
//  }
//
//  // Reference to _defaultActorEnqueue.
//  auto fnRef = new (ctx) DeclRefExpr(fn, DeclNameLoc(), /*Implicit=*/true);
//  fnRef->setType(fn->getInterfaceType());
//
//  // self argument to the function.
//  auto selfDecl = enqueuePartialTask->getImplicitSelfDecl();
//  Type selfType = enqueuePartialTask->mapTypeIntoContext(
//      selfDecl->getValueInterfaceType());
//  Expr *selfArg = new (ctx) DeclRefExpr(
//      selfDecl, DeclNameLoc(), /*Implicit=*/true, AccessSemantics::Ordinary,
//      selfType);
//  selfArg = ErasureExpr::create(ctx, selfArg, ctx.getAnyObjectType(), { });
//  selfArg->setImplicit();
//
//  // The partial asynchronous task.
//  auto partialTaskParam = enqueuePartialTask->getParameters()->get(0);
//  Expr *partialTask = new (ctx) DeclRefExpr(
//      partialTaskParam, DeclNameLoc(), /*Implicit=*/true,
//      AccessSemantics::Ordinary,
//      enqueuePartialTask->mapTypeIntoContext(
//        partialTaskParam->getValueInterfaceType()));
//
//  // Form the call itself.
//  auto call = CallExpr::createImplicit(
//      ctx, fnRef, { partialTask, selfArg },
//      { ctx.Id_partialTask, ctx.getIdentifier("actor") });
//  call->setType(fn->getResultInterfaceType());
//  call->setThrows(false);
//
//  auto body = BraceStmt::create(
//      ctx, SourceLoc(), { call }, SourceLoc(), /*implicit=*/true);
//  return { body, /*isTypeChecked=*/true };
//}
//

///// Synthesizer callback for an empty implicit function body.
//static std::pair<BraceStmt *, bool>
//synthesizeEmptyFunctionBody(AbstractFunctionDecl *afd, void *context) {
//  ASTContext &ctx = afd->getASTContext();
//  return { BraceStmt::create(ctx, afd->getLoc(), { }, afd->getLoc(), true),
//      /*isTypeChecked=*/true };
//}


/// Synthesizes the body for:
///
/// ```
/// init(resolve address: ActorAddress, using transport: ActorTransport)
/// ```
///
/// \param initDecl The function decl whose body to synthesize.
static std::pair<BraceStmt *, bool>
deriveBodyDistributedActor_init_address(AbstractFunctionDecl *initDecl, void *) {
  // TODO: init(proxyFor: ActorAddress, using transport: ActorTransport)
  assert(false && "not implemented yet");
}

/// Synthesizes the body for `init(transport: ActorTransport)`.
///
/// \param initDecl The function decl whose body to synthesize.
static std::pair<BraceStmt *, bool>
deriveBodyDistributedActor_init_transport(AbstractFunctionDecl *initDecl, void *) {
  // distributed actor class Greeter {
  //   // Already derived by this point if possible.
  //   @derived let actorTransport: ActorTransport
  //   @derived let address: ActorAddress
  //
  //   @derived init(transport: ActorTransport) throws { // TODO: make it throwing?
  //     self.actorTransport = transport
  //     // self.address = try transport.allocateAddress(self)// TODO: implement this
  //   }
  // }

  // The enclosing type decl.
  auto conformanceDC = initDecl->getDeclContext();
  auto *targetDecl = conformanceDC->getSelfNominalTypeDecl();

  auto *funcDC = cast<DeclContext>(initDecl);
  auto &C = funcDC->getASTContext();

  // TODO: assert the fields are present

  SmallVector<ASTNode, 2> statements;

  auto transportParam = initDecl->getParameters()->get(0);
  auto *transportExpr = new (C) DeclRefExpr(ConcreteDeclRef(transportParam),
                                            DeclNameLoc(), /*Implicit=*/true);

  // `self.actorTransport = transport`

  //  // TODO: Don't output a decode statement for a let with an initial value.
//  // Don't output a decode statement for a let with an initial value.
//  if (varDecl->isLet() && varDecl->isParentInitialized()) {
//   // TODO: this can be done by users who want their actor to magically use a specific global transport always
//  }

  auto *selfRef = DerivedConformance::createSelfDeclRef(initDecl);
  auto *varExpr = UnresolvedDotExpr::createImplicit(C, selfRef,
                                                    C.Id_actorTransport);
  auto *assignExpr = new (C) AssignExpr(varExpr, SourceLoc(), transportExpr,
                                        /*Implicit=*/true);
  statements.push_back(assignExpr);

  auto *body = BraceStmt::create(C, SourceLoc(), statements, SourceLoc(),
      /*implicit=*/true);

  fprintf(stderr, "[%s:%d] >> (%s) %s  \n", __FILE__, __LINE__, __FUNCTION__, "INIT transport BODY:");
  initDecl->dump();

  return { body, /*isTypeChecked=*/false };
}

/// Returns whether the given type is valid for synthesizing the transport
/// initializer.
///
/// Checks to see whether the given type has has already defined such initializer,
/// and if not attempts to synthesize it.
///
/// \param requirement The requirement we want to synthesize.
static bool canSynthesizeInitializer(DerivedConformance &derived, ValueDecl *requirement) {
  return true; // TODO: replace with real impl
}

/// Derive the declaration of Actor's resolve initializer.
///
/// Swift signature:
/// ```
///   init(resolve address: ActorAddress, using transport: ActorTransport) throws
/// ```
static ValueDecl *deriveDistributedActor_init_resolve(DerivedConformance &derived) {
  fprintf(stderr, "[%s:%d] >> (%s) %s  \n", __FILE__, __LINE__, __FUNCTION__, "TODO IMPLEMENT THIS SYNTHESIS");

  return nullptr;
}


/// Derive the declaration of Actor's local initializer.
/// Swift signature:
/// ```
///   init(transport actorTransport: ActorTransport) { ... }
/// ```
static ValueDecl *deriveDistributedActor_init_transport(DerivedConformance &derived) {
  ASTContext &C = derived.Context;

  auto classDecl = dyn_cast<ClassDecl>(derived.Nominal);
  auto conformanceDC = derived.getConformanceContext();

  // Expected type: (Self) -> (ActorTransport) -> (Self)
  //
  // Params: (transport actorTransport: ActorTransport)
  auto transportType = C.getActorTransportDecl()->getDeclaredInterfaceType();
  auto *transportParamDecl = new (C) ParamDecl(
      SourceLoc(), SourceLoc(), C.Id_transport,
      SourceLoc(), C.Id_actorTransport, conformanceDC);
  transportParamDecl->setImplicit();
  transportParamDecl->setSpecifier(ParamSpecifier::Default);
  transportParamDecl->setInterfaceType(transportType);
  fprintf(stderr, "[%s:%d] >> (%s) %s  \n", __FILE__, __LINE__, __FUNCTION__, "param prepared");

  auto *paramList = ParameterList::createWithoutLoc(transportParamDecl);

  // Func name: init(transport:)
  fprintf(stderr, "[%s:%d] >> (%s) %s  \n", __FILE__, __LINE__, __FUNCTION__, "init func");
  DeclName name(C, DeclBaseName::createConstructor(), paramList);

  auto *initDecl =
      new (C) ConstructorDecl(name, SourceLoc(),
                              /*Failable=*/false, SourceLoc(),
                              /*Throws=*/false, SourceLoc(), paramList, // TODO: make it throws?
                              /*GenericParams=*/nullptr, conformanceDC);
  initDecl->setImplicit();
  initDecl->setSynthesized(); // TODO: consider making throwing
  initDecl->setBodySynthesizer(&deriveBodyDistributedActor_init_transport);
  fprintf(stderr, "[%s:%d] >> (%s) %s  \n", __FILE__, __LINE__, __FUNCTION__, "init func prepared");

  // This constructor is 'required', all distributed actors MUST invoke it.
  // TODO: this makes sense I guess, and we should ban defining such constructor at all.
  auto *reqAttr = new (C) RequiredAttr(/*IsImplicit*/true);
  initDecl->getAttrs().add(reqAttr);

  initDecl->copyFormalAccessFrom(derived.Nominal,
                                 /*sourceIsParentContext=*/true);
  derived.addMembersToConformanceContext({initDecl});
  fprintf(stderr, "[%s:%d] >> (%s) %s  \n", __FILE__, __LINE__, __FUNCTION__, "added");

  fprintf(stderr, "[%s:%d] >> (%s) %s  \n", __FILE__, __LINE__, __FUNCTION__, "INIT DECL:");
  initDecl->dump();

  return initDecl;

//  fprintf(stderr, "[%s:%d] >> TODO: SYNTHESIZE (%s)  \n", __FILE__, __LINE__, __FUNCTION__);
//  // TODO: synthesize the initializer accepting the transport,
//  // - store the transport as actorTransport
//  // - invoke the transport to allocate an address, store it as actorAddress
//
//  return nullptr;
}

/// Derive the declaration of Actor's actorTransport.
static ValueDecl *deriveDistributedActor_actorTransport(DerivedConformance &derived) {
  ASTContext &ctx = derived.Context;

//  auto *funcDC = cast<DeclContext>(initDecl); // TODO: how?????
//  auto &C = funcDC->getASTContext();

  fprintf(stderr, "[%s:%d] >> TODO: SYNTHESIZE (%s)  \n", __FILE__, __LINE__, __FUNCTION__);
  // TODO: actually implement the transport field

//  VarDecl *varDecl = = new (Ctx) VarDecl(/*IsStatic*/false, VarDecl::Introducer::Let,
//                                               SourceLoc(), C.Id_actorTransport, Get);
//  varDecl->setInterfaceType(MaybeLoadInitExpr->getType()->mapTypeOutOfContext());
//  varDecl->setImplicit();
//
//  derived.addMembersToConformanceContext({varDecl});
//
//  return varDecl;

  return nullptr;
}

/// Derive the declaration of Actor's actorAddress.
static ValueDecl *deriveDistributedActor_actorAddress(DerivedConformance &derived) {
  ASTContext &ctx = derived.Context;

  fprintf(stderr, "[%s:%d] >> TODO: SYNTHESIZE (%s)  \n", __FILE__, __LINE__, __FUNCTION__);
  // TODO: actually implement the address field
  return nullptr;
}

ValueDecl *DerivedConformance::deriveDistributedActor(ValueDecl *requirement) {
  // Synthesize properties
////  auto var = dyn_cast<VarDecl>(requirement);
////  if (var) {
////    if (VarDecl::isDistributedActorTransportName(Context, var->getName())) {
////      fprintf(stderr, "[%s:%d] >> (%s)  \n", __FILE__, __LINE__, __FUNCTION__);
////      return deriveDistributedActor_actorTransport(*this);
////    }
////
////    if (VarDecl::isDistributedActorAddressName(Context, var->getName())) {
////      fprintf(stderr, "[%s:%d] >> (%s)  \n", __FILE__, __LINE__, __FUNCTION__);
////      return deriveDistributedActor_actorAddress(*this);
////    }
////  }
////
////  // Synthesize functions
////  auto func = dyn_cast<FuncDecl>(requirement);
////  if (func) {
////    // TODO: derive encode impl
////    return nullptr;
////  }
//
//  // Synthesize initializers
//  auto ctor = dyn_cast<ConstructorDecl>(requirement);
//  if (ctor) {
//    const auto name = requirement->getName();
//    auto argumentNames = name.getArgumentNames();
//
//    if (argumentNames.size() == 1) {
//      // TODO: check param labels too here? but we checked already in DerivedConformances.
//      fprintf(stderr, "[%s:%d] >> (%s)  \n", __FILE__, __LINE__, __FUNCTION__);
//      return deriveDistributedActor_init_transport(*this);
//    } else if (argumentNames.size() == 2) {
//      fprintf(stderr, "[%s:%d] >> (%s)  \n", __FILE__, __LINE__, __FUNCTION__);
//      return deriveDistributedActor_init_resolve(*this);
//    }
//  }

 return nullptr;
}
