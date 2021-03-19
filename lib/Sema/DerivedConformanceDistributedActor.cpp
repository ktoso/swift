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

#include "CodeSynthesis.h"
#include "DerivedConformances.h"
#include "TypeChecker.h"
#include "TypeCheckConcurrency.h"
#include "swift/AST/NameLookupRequests.h"
#include "swift/AST/ParameterList.h"

using namespace swift;

bool DerivedConformance::canDeriveDistributedActor(NominalTypeDecl *nominal) {
  auto classDecl = dyn_cast<ClassDecl>(nominal);
  return classDecl && classDecl->isDistributedActor();
}


/******************************************************************************/
/************************************ MISC ************************************/
/******************************************************************************/


/// Create a stub body that emits a fatal error message.
static std::pair<BraceStmt *, bool>
______synthesizeStubBody(AbstractFunctionDecl *fn, void *) {
  auto *ctor = cast<ConstructorDecl>(fn);
  auto &ctx = ctor->getASTContext();

  auto unimplementedInitDecl = ctx.getUnimplementedInitializer();
  auto classDecl = ctor->getDeclContext()->getSelfClassDecl();
  if (!unimplementedInitDecl) {
    ctx.Diags.diagnose(classDecl->getLoc(),
                       diag::missing_unimplemented_init_runtime);
    return { nullptr, true };
  }

  auto *staticStringDecl = ctx.getStaticStringDecl();
  auto staticStringType = staticStringDecl->getDeclaredInterfaceType();
  auto staticStringInit = ctx.getStringBuiltinInitDecl(staticStringDecl);

  auto *uintDecl = ctx.getUIntDecl();
  auto uintType = uintDecl->getDeclaredInterfaceType();
  auto uintInit = ctx.getIntBuiltinInitDecl(uintDecl);

  // Create a call to Swift._unimplementedInitializer
  auto loc = classDecl->getLoc();
  Expr *ref = new (ctx) DeclRefExpr(unimplementedInitDecl,
                                    DeclNameLoc(loc),
      /*Implicit=*/true);
  ref->setType(unimplementedInitDecl->getInterfaceType()
                   ->removeArgumentLabels(1));

  llvm::SmallString<64> buffer;
  StringRef fullClassName = ctx.AllocateCopy(
      (classDecl->getModuleContext()->getName().str() +
       "." +
       classDecl->getName().str()).toStringRef(buffer));

  auto *className = new (ctx) StringLiteralExpr(fullClassName, loc,
      /*Implicit=*/true);
  className->setBuiltinInitializer(staticStringInit);
  assert(isa<ConstructorDecl>(className->getBuiltinInitializer().getDecl()));
  className->setType(staticStringType);

  auto *initName = new (ctx) MagicIdentifierLiteralExpr(
      MagicIdentifierLiteralExpr::Function, loc, /*Implicit=*/true);
  initName->setType(staticStringType);
  initName->setBuiltinInitializer(staticStringInit);

  auto *file = new (ctx) MagicIdentifierLiteralExpr(
      MagicIdentifierLiteralExpr::FileID, loc, /*Implicit=*/true);
  file->setType(staticStringType);
  file->setBuiltinInitializer(staticStringInit);

  auto *line = new (ctx) MagicIdentifierLiteralExpr(
      MagicIdentifierLiteralExpr::Line, loc, /*Implicit=*/true);
  line->setType(uintType);
  line->setBuiltinInitializer(uintInit);

  auto *column = new (ctx) MagicIdentifierLiteralExpr(
      MagicIdentifierLiteralExpr::Column, loc, /*Implicit=*/true);
  column->setType(uintType);
  column->setBuiltinInitializer(uintInit);

  auto *call = CallExpr::createImplicit(
      ctx, ref, { className, initName, file, line, column }, {});
  call->setType(ctx.getNeverType());
  call->setThrows(false);

  SmallVector<ASTNode, 2> stmts;
  stmts.push_back(call);
  stmts.push_back(new (ctx) ReturnStmt(SourceLoc(), /*Result=*/nullptr));
  return { BraceStmt::create(ctx, SourceLoc(), stmts, SourceLoc(),
      /*implicit=*/true),
      /*isTypeChecked=*/true };
}

// ==== ------------------------------------------------------------------------

// TODO: deduplicate with 'declareDerivedProperty' from DerivedConformance...
// FIXME: !!!!!!!!!!!!!!!!!!!!!
std::pair<VarDecl *, PatternBindingDecl *>
createStoredProperty(ValueDecl *parent, DeclContext *parentDC, ASTContext &ctx,
                     VarDecl::Introducer introducer, Identifier name,
                     Type propertyInterfaceType, Type propertyContextType,
                     bool isStatic, bool isFinal,
                     llvm::Optional<AccessLevel> accessLevel = llvm::None);


// TODO: similar to getVarNameForCoding, so maybe move it onto VarDecl
static Identifier getVarName(VarDecl *var) {
  if (auto originalVar = var->getOriginalWrappedProperty())
    return originalVar->getName();

  return var->getName();
}


/******************************************************************************/
/*********************************** TYPES ************************************/
/******************************************************************************/

static Type
getBoundPersonalityStorageType(ASTContext &C,
                               DeclContext* parentDC,
                               NominalTypeDecl *decl) {
  // === DistributedActorStorage<?>
  auto storageTypeDecl = C.getDistributedActorStorageDecl();

  // === locate the SYNTHESIZED: LocalStorage
  auto localStorageTypeDecls = decl->lookupDirect(DeclName(C.Id_DistributedActorLocalStorage));

//  if (localStorageTypeDecls.size() > 1) {
//    assert(false && "Only a single DistributedActorLocalStorage type may be declared!");
//  }
  StructDecl *localStorageDecl = nullptr;
  for (auto decl : localStorageTypeDecls) {
    fprintf(stderr, "\n");
    fprintf(stderr, "[%s:%d] (%s) STORAGE DECL:\n", __FILE__, __LINE__, __FUNCTION__);
    decl->dump();
    fprintf(stderr, "\n");
    if (auto structDecl = dyn_cast<StructDecl>(decl)) {
      localStorageDecl = structDecl;
      break;
    }
  }

//  localStorageDecl->dump();
//  fprintf(stderr, "[%s:%d] (%s) localStorageDecl ^^^^^^\n", __FILE__, __LINE__, __FUNCTION__);
  assert(localStorageDecl && "unable to lookup SYNTHESIZED struct DistributedActorLocalStorage!");
//  TypeDecl *localStorageTypeDecl = dyn_cast<TypeDecl>(localStorageDecl);
//  if (!localStorageTypeDecl) {
//    // TODO: diagnose here
//    assert(false && "could not find DistributedActorLocalStorage in distributed actor");
//  }

  // === bind: DistributedActorStorage<DistributedActorLocalStorage>
  auto localStorageType = localStorageDecl->getDeclaredInterfaceType();
//    if (isa<TypeAliasDecl>(localStorageType)) // TODO: doug, ??????
//      localStorageType = localStorageType->getAnyNominal();

//  auto boundStorageType = BoundGenericType::get(
//      storageTypeDecl, /*Parent=*/Type(), {localStorageType});

  auto rawTy = C.getStringDecl();

  fprintf(stderr, "[%s:%d] (%s) STRING:\n", __FILE__, __LINE__, __FUNCTION__);
  rawTy->dump();
  fprintf(stderr, "[%s:%d] (%s) STRING getDeclaredInterfaceType:\n", __FILE__, __LINE__, __FUNCTION__);
  rawTy->getDeclaredInterfaceType()->dump();
  fprintf(stderr, "[%s:%d] (%s) localStorageDecl:\n", __FILE__, __LINE__, __FUNCTION__);
  localStorageDecl->dump();
  fprintf(stderr, "[%s:%d] (%s) localStorageDecl getDeclaredInterfaceType:\n", __FILE__, __LINE__, __FUNCTION__);
  localStorageDecl->getDeclaredInterfaceType()->dump();
  fprintf(stderr, "[%s:%d] (%s) localStorageDecl mapped getDeclaredInterfaceType:\n", __FILE__, __LINE__, __FUNCTION__);
  decl->mapTypeIntoContext(localStorageDecl->getDeclaredInterfaceType())->dump();
//  auto bareTypeExpr = TypeExpr::createImplicit(rawTy, C);
//  auto typeExpr = new (C) DotSelfExpr(bareTypeExpr, SourceLoc(), SourceLoc());

  auto boundStorageType = BoundGenericType::get(
//      storageTypeDecl, /*Parent=*/Type(), {rawTy->getDeclaredInterfaceType()});
//      storageTypeDecl, /*Parent=*/Type(), {localStorageDecl->getDeclaredInterfaceType()});
      storageTypeDecl, /*Parent=*/Type(),
      {decl->mapTypeIntoContext(localStorageDecl->getDeclaredInterfaceType())});

  return boundStorageType;
}

/// Create a `$Storage` type that mirrors all stored properties of a distributed actor.
///
/// E.g. for the following distributed actor:
///
///     distributed actor Greeter {
///         var name: String
///     }
///
/// to be represented as:
///
///     distributed actor Greeter {
///       @derived
///       private struct Storage {
///         var name: String
///       }
///
///       @distributedActorState var name: String
///     }
///
/// Where the `distributedActorState` property wrapper is implemented as
static std::pair<Type, TypeDecl *>
deriveDistributedActorLocalStorageStruct(DerivedConformance &derived) {
  auto *parentDC = derived.getConformanceContext();
  auto nominal = dyn_cast<ClassDecl>(derived.Nominal);
  auto &C = derived.Nominal->getASTContext();
  assert(nominal->isDistributedActor());

  fprintf(stderr, "\n");
  nominal->dump();
  fprintf(stderr, "[%s:%d] (%s) SYNTH STORAGE FOR ^^^^^^\n", __FILE__, __LINE__, __FUNCTION__);


  StructDecl *storageDecl = new (C) StructDecl(
      SourceLoc(), C.Id_DistributedActorLocalStorage, SourceLoc(),
      /*Inherited*/ {},
      /*GenericParams*/ {}, nominal
  );
  storageDecl->setImplicit();
//  storageDecl->setSynthesized();
  // storageDecl->setAccess(AccessLevel::Private); // TODO: would love for these to be private (!!!)
  storageDecl->copyFormalAccessFrom(nominal, /*sourceIsParentContext=*/true); // TODO: unfortunate
  // storageDecl->setUserAccessible(false); // TODO: would be nice

  // mirror all stored properties from the 'distributed actor' to the storage struct.
  // This must not use 'getStoredProperties' as it would create a cycle.
  for (auto *member : nominal->getMembers()) {
    VarDecl *var = dyn_cast<VarDecl>(member);
    if (!var || var->isStatic() || !var->isUserAccessible())
      continue;

    fprintf(stderr, "[%s:%d] (%s) mirror [%s] to DistributedActorLocalStorage.%s\n",
            __FILE__, __LINE__, __FUNCTION__, var->getBaseName(), var->getBaseName());


    VarDecl *propDecl;
    PatternBindingDecl *pbDecl;
    auto propertyType = var->getInterfaceType();
    std::tie(propDecl, pbDecl) = createStoredProperty(
        storageDecl, storageDecl, C,
        VarDecl::Introducer::Var, getVarName(var), // TODO: copy whether it was a Var or a Let
        propertyType, propertyType,
        /*isStatic=*/false, /*isFinal=*/false); // TODO: if Let then make it final

    storageDecl->addMember(propDecl);
    storageDecl->addMember(pbDecl);
  }

  fprintf(stderr, "\n", __FILE__, __LINE__, __FUNCTION__);
  storageDecl->dump();
  fprintf(stderr, "[%s:%d] (%s) SYNTHESIZED STORAGE STRUCT\n", __FILE__, __LINE__, __FUNCTION__);

  derived.addMembersToConformanceContext({storageDecl});

  return std::make_pair(
      parentDC->mapTypeIntoContext(
          storageDecl->getInterfaceType()),
//      storageDecl->getInterfaceType(),
      storageDecl
  );
}

/******************************************************************************/
/******************************** FUNCTIONS ***********************************/
/******************************************************************************/

/// Return the `KeyPath<Self.DistributedActorLocalStorage, T>`
/// specific to this distributed actor.
static BoundGenericClassType*
getBoundKeyPathLocalStorageToT(ASTContext &C, NominalTypeDecl *decl, Type genericT) {
  fprintf(stderr, "[%s:%d] (%s) getBoundPersonalityStorageType\n", __FILE__, __LINE__, __FUNCTION__);

  // === DistributedActorStorage<?>
  auto *keyPathDecl = dyn_cast<ClassDecl>(C.getKeyPathDecl());
  keyPathDecl->dump();

  // === locate the synthesized: DistributedActorLocalStorage
  // TODO: make getLocalStorageDecl func here, we do this a few times
  auto localStorageDecls = decl->lookupDirect(DeclName(C.Id_DistributedActorLocalStorage));
//  if (localStorageDecls.size() > 1) {
//    assert(false && "Only a single DistributedActorLocalStorage type may be declared!");
//  }
  StructDecl *localStorageDecl = nullptr;
  for (auto decl : localStorageDecls) {
    fprintf(stderr, "\n");
    fprintf(stderr, "[%s:%d] (%s) DECL:\n", __FILE__, __LINE__, __FUNCTION__);
    decl->dump();
    fprintf(stderr, "\n");

    if (auto structDecl = dyn_cast<StructDecl>(decl)) {
      localStorageDecl = structDecl;
      break;
    }
  }
  assert(localStorageDecl && "unable to lookup synthesized struct DistributedActorLocalStorage!");
//  TypeDecl *localStorageTypeDecl = dyn_cast<TypeDecl>(localkeyPathDecl);
//  if (!localStorageTypeDecl) {
//    // TODO: diagnose here
//    assert(false && "could not find DistributedActorLocalStorage in distributed actor");
//  }

  // === bind: KeyPath<DistributedActorLocalStorage, T>
  auto localStorageType = localStorageDecl->getInterfaceType();
//    if (isa<TypeAliasDecl>(localStorageType))
//      localStorageType = localStorageType->getAnyNominal();

  return BoundGenericClassType::get(
      keyPathDecl, /*Parent=*/Type(),
      {localStorageType, genericT});
  //      ->getCanonicalType();
}

//static std::pair<BraceStmt *, bool>
//createBody_DistributedActor_mapStorage(AbstractFunctionDecl *funcDecl, void *) {
//  auto DC = funcDecl->getDeclContext();
//  auto actorDecl = dyn_cast<ClassDecl>(DC->getParent());
//  ASTContext &C = funcDecl->getASTContext();
//
//  fprintf(stderr, "\n");
//  actorDecl->dump();
//  fprintf(stderr, "[%s:%d] (%s) ACTOR DECL IS ^^^^\n", __FILE__, __LINE__, __FUNCTION__);
//
//  SmallVector<ASTNode, 4> statements;
//
//  // --- Parameters
//  auto pathParam = funcDecl->getParameters()->get(0);
//  auto pathExpr = new (C) DeclRefExpr(ConcreteDeclRef(pathParam),
//                                      DeclNameLoc(), /*Implicit=*/true);
//
//  // --- Types
//  auto anyKeyPathType = C.getAnyKeyPathDecl()->getDeclaredInterfaceType();
//
//  auto *selfRef = DerivedConformance::createSelfDeclRef(funcDecl);
//  auto selfType = funcDecl->getInnermostTypeContext()->getSelfTypeInContext();
//
//  // --- Switch patterns and bodies
//  // = for each _distributedActorState property
//  // === case \<actor>.<prop>: return \LocalStorage.<prop> as! KeyPath<LocalStorage, T>
//  for (auto *member : actorDecl->getMembers()) {
//    VarDecl *var = dyn_cast<VarDecl>(member);
//    if (!var || var->isStatic() || !var->isUserAccessible())
//      continue;
//
//    // (case_label_item
//    //  (pattern_expr type='AnyKeyPath'
//    //    (binary_expr implicit type='Bool' nothrow
//    //      (declref_expr implicit type='(AnyKeyPath, AnyKeyPath) -> Bool'
//    //          decl=Swift.(file).~= [with (substitution_map generic_signature=<T where T : Equatable> (substitution T -> AnyKeyPath))]
//    //          function_ref=compound)
//    //      (tuple_expr implicit type='(AnyKeyPath, AnyKeyPath)'
//    //        (derived_to_base_expr implicit type='AnyKeyPath'
//    //          (keypath_expr type='KeyPath<Person, String>'
//    //            (components
//    //              (property decl=main.(file).Person.name@<stdin>:12:9 type='String'))
//    //            (parsed_root
//    //              (unresolved_dot_expr type='<null>' field 'name' function_ref=unapplied
//    //                (type_expr type='<null>' typerepr='Person')))))
//    //        (declref_expr implicit type='AnyKeyPath'
//    //            decl=main.(file).Person._mapStorage(keyPath:).$match@<stdin>:22:14 function_ref=unapplied)))))
//    ////////////////
//    //  (brace_stmt implicit range=[<stdin>:23:13 - line:23:98]
//    //    (return_stmt range=[<stdin>:23:13 - line:23:98]
//    //      (forced_checked_cast_expr type='KeyPath<Person.DistributedActorLocalStorage, T>' value_cast writtenType='KeyPath<Person.DistributedActorLocalStorage, T>'
//    //        (keypath_expr type='KeyPath<Person.DistributedActorLocalStorage, String>'
//    //          (components
//    //            (property decl=main.(file).Person.DistributedActorLocalStorage.name@<stdin>:17:13 type='String'))
//    //          (parsed_root
//    //            (unresolved_dot_expr type='<null>' field 'name' function_ref=unapplied
//    //              (type_expr type='<null>' typerepr='DistributedActorLocalStorage'))))))))
//
//    // === case \<actor>.prop:
//    auto pat = new (C) ExprPattern(
//        TypeExpr::createImplicit(anyKeyPathType, C), SourceLoc(),
//        DeclNameLoc(), DeclNameRef(), elt, subpattern);
//    pat->setImplicit();
//
//    SmallVector<ASTNode, 3> caseStatements;
//
//    auto labelItem = CaseLabelItem(pat);
//    auto body = BraceStmt::create(C, SourceLoc(), caseStatements, SourceLoc());
//    cases.push_back(CaseStmt::create(C, CaseParentKind::Switch, SourceLoc(),
//                                     labelItem, SourceLoc(), SourceLoc(), body,
//                                     /*case body vardecls*/ caseBodyVarDecls));
//  }
//
//  // === switch keyPath { }
//  {
//    auto switchStmt = SwitchStmt::create(LabeledStmtInfo(), SourceLoc(), pathExpr,
//                                         SourceLoc(), cases, SourceLoc(), C);
//    statements.push_back(switchStmt);
//  };
//
//  auto *body = BraceStmt::create(C, SourceLoc(), statements, SourceLoc(),
//      /*implicit=*/true);
//
//  return { body, /*isTypeChecked=*/false };
//}

/// (func_decl "_mapStorage(keyPath:)" <T> interface type='<Self, T where Self : DistributedActor> (Self.Type) -> (AnyKeyPath) -> KeyPath<Self.DistributedActorLocalStorage, T>' access=public type
//  (parameter "self")
//  (parameter_list
//    (parameter "keyPath" apiName=keyPath type='AnyKeyPath' interface type='AnyKeyPath')))
static ValueDecl*
deriveDistributedActorFuncMapStorage(DerivedConformance &derived) {
  auto *nominal = derived.Nominal;
  auto &C = derived.Nominal->getASTContext();

  fprintf(stderr, "[%s:%d] (%s) TODO SYNTHESIZE _mapStorage\n", __FILE__, __LINE__, __FUNCTION__);

  // Expected type: <T> (Person.Type) -> (AnyKeyPath) -> KeyPath<Person.DistributedActorLocalStorage, T>
  //
  // Params: (keyPath: AnyKeyPath)
  auto anyKeyPathType = C.getAnyKeyPathDecl()->getDeclaredInterfaceType();
  auto *keyPathParamDecl = new (C) ParamDecl(
      SourceLoc(), SourceLoc(), C.Id_keyPath,
      SourceLoc(), C.Id_keyPath, derived.Nominal);
  keyPathParamDecl->setImplicit();
  keyPathParamDecl->setSpecifier(ParamSpecifier::Default);
  keyPathParamDecl->setInterfaceType(anyKeyPathType);

  auto params = ParameterList::createWithoutLoc(keyPathParamDecl);

  // Func name: _mapStorage(keyPath:)
  DeclName name(C, C.Id_mapStorage, params);

  // KeyPath<Self.DistributedActorLocalStorage, T>
  auto theT = CanGenericTypeParamType::get(0, 0, C);
  theT->dump();
  fprintf(stderr, "[%s:%d] (%s) THE T ^^^^\n", __FILE__, __LINE__, __FUNCTION__);
  Type returnType = getBoundKeyPathLocalStorageToT(C, nominal, theT);
  returnType->dump();
  fprintf(stderr, "[%s:%d] (%s) THE returnType ^^^^\n", __FILE__, __LINE__, __FUNCTION__);

  // --- <T> generic for the func
  SmallVector<GenericTypeParamDecl *, 1> genericTypeParamDecls;
    auto *singleTypeParam = new (C) GenericTypeParamDecl(
        nominal, C.getIdentifier("T"), SourceLoc(),
        GenericTypeParamDecl::InvalidDepth,
        /*index=*/0);
  singleTypeParam->setImplicit(true);
  genericTypeParamDecls.push_back(singleTypeParam);
  auto genericParams = GenericParamList::create(
      C, SourceLoc(), genericTypeParamDecls, SourceLoc());

  // === func _mapStorage<T>(keyPath:) -> KeyPath<LocalStorate, T>
  auto *funcDecl = FuncDecl::createImplicit(
      C, StaticSpellingKind::KeywordStatic, name, /*NameLoc=*/SourceLoc(),
      /*Async=*/false, /*Throws=*/false,
      genericParams, params, returnType, nominal);
  funcDecl->setImplicit();
  funcDecl->setSynthesized();
  // funcDecl->setBodySynthesizer(&createBody_DistributedActor_mapStorage); // FIXME: actually implement the body synthesis!!!!!!
  funcDecl->setBodySynthesizer(______synthesizeStubBody);
  funcDecl->copyFormalAccessFrom(nominal, /*sourceIsParentContext=*/true); // TODO: make private?

//  funcDecl->setGenericSignature();

  fprintf(stderr, "\n", __FILE__, __LINE__, __FUNCTION__);
  funcDecl->dump();
  fprintf(stderr, "[%s:%d] (%s) SYNTHESIZED FUNC _MAPSTORAGE ^^^^^\n", __FILE__, __LINE__, __FUNCTION__);

  return funcDecl;
}

/******************************************************************************/
/******************************** PROPERTIES **********************************/
/******************************************************************************/

/// Synthesize the 'actorAddress' stored property.
/// 
/// ```
/// @_distributedActorIndependent
/// let actorAddress: ActorAddress
/// ```
/// (no need for @actorIndependent because it is an immutable let)
static ValueDecl*
deriveDistributedActorPropertyAddress(DerivedConformance &derived) {
  auto actorDecl = dyn_cast<ClassDecl>(derived.Nominal);
  assert(actorDecl->isDistributedActor());

  auto &C = derived.Nominal->getASTContext();

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
      new(C) DistributedActorIndependentAttr(/*IsImplicit=*/true));


  fprintf(stderr, "\n", __FILE__, __LINE__, __FUNCTION__);
  propDecl->dump();
  pbDecl->dump();
  fprintf(stderr, "[%s:%d] (%s) SYNTHESIZED PROPERTY ADDRESS\n", __FILE__, __LINE__, __FUNCTION__);

  derived.addMembersToConformanceContext({propDecl, pbDecl});
  return propDecl;
}

/// Synthesize the 'actorTransport' stored property.
///
/// ```
/// @_distributedActorIndependent
/// let actorTransport: ActorTransport
/// ```
/// (no need for @actorIndependent because it is an immutable let)
static ValueDecl*
deriveDistributedActorPropertyTransport(DerivedConformance &derived) {
  auto actorDecl = dyn_cast<ClassDecl>(derived.Nominal);
  assert(actorDecl->isDistributedActor());

  auto &C = derived.Nominal->getASTContext();

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
      new(C) DistributedActorIndependentAttr(/*IsImplicit=*/true));


  fprintf(stderr, "\n", __FILE__, __LINE__, __FUNCTION__);
  propDecl->dump();
  pbDecl->dump();
  fprintf(stderr, "[%s:%d] (%s) SYNTHESIZED PROPERTY TRANSPORT\n", __FILE__, __LINE__, __FUNCTION__);

  derived.addMembersToConformanceContext({propDecl, pbDecl});
  return propDecl;
}

// ```
// private var storage: DistributedActorStorage<LocalStorage>
// ```
static ValueDecl*
deriveDistributedActorPropertyStorage(DerivedConformance &derived) {
  auto *parentDC = derived.getConformanceContext();
  auto actorDecl = dyn_cast<ClassDecl>(derived.Nominal);
  auto &C = derived.Nominal->getASTContext();
  assert(actorDecl->isDistributedActor());


  auto boundPersonalityType = getBoundPersonalityStorageType(C, parentDC, actorDecl);

  VarDecl *propDecl;
  PatternBindingDecl *pbDecl;
  std::tie(propDecl, pbDecl) = createStoredProperty(
      actorDecl, actorDecl, C,
      VarDecl::Introducer::Var, C.Id_storage,
      boundPersonalityType, boundPersonalityType,
      /*isStatic=*/false, /*isFinal=*/false);

//    // Mark it private, only the actor itself can access storage.
//    propDecl->setAccess(AccessLevel::Private); // TODO: do this, but this fails on 'access already set' we must set this at creation inside the createStoredProperty

//    // FIXME: we need to somehow mark it to not be included in "slap property wrappers on things"
//    //       however independent is the wrong thing; so I guess just the SYNTHESIZED or implicit thing?
//    // SEE ALSO: isDistributedActorStoredProperty which would be part of the fix
  propDecl->getAttrs().add(
      new(C) DistributedActorIndependentAttr(/*IsImplicit=*/true));


  fprintf(stderr, "\n", __FILE__, __LINE__, __FUNCTION__);
  propDecl->dump();
  pbDecl->dump();
  fprintf(stderr, "[%s:%d] (%s) SYNTHESIZED PROPERTY STORAGE\n", __FILE__, __LINE__, __FUNCTION__);

  derived.addMembersToConformanceContext({propDecl, pbDecl});
  return propDecl;
}

// ==== ------------------------------------------------------------------------

// TODO: remove, this is not actually used nowadays, we do this in CodeSynthesisDistributedActor
ValueDecl *DerivedConformance::deriveDistributedActor(ValueDecl *requirement) {

  fprintf(stderr, "\n");
  requirement->dump();
  fprintf(stderr, "[%s:%d] (%s) deriveDistributedActor\n", __FILE__, __LINE__, __FUNCTION__);

  if (dyn_cast<VarDecl>(requirement)) {
    auto name = requirement->getName();
    if (name == Context.Id_actorAddress) {
      auto x = deriveDistributedActorPropertyAddress(*this);
      fprintf(stderr, "[%s:%d] (%s) ================================================\n", __FILE__, __LINE__, __FUNCTION__);
      this->Nominal->dump();
      fprintf(stderr, "[%s:%d] (%s) ================================================\n", __FILE__, __LINE__, __FUNCTION__);
      return x;
    }
    if (name == Context.Id_actorTransport) {
      auto x =  deriveDistributedActorPropertyTransport(*this);
      fprintf(stderr, "[%s:%d] (%s) ================================================\n", __FILE__, __LINE__, __FUNCTION__);
      this->Nominal->dump();
      fprintf(stderr, "[%s:%d] (%s) ================================================\n", __FILE__, __LINE__, __FUNCTION__);
      return x;
    }
    if (name == Context.Id_storage) {
      auto x = deriveDistributedActorPropertyStorage(*this);
      fprintf(stderr, "[%s:%d] (%s) ================================================\n", __FILE__, __LINE__, __FUNCTION__);
      this->Nominal->dump();
      fprintf(stderr, "[%s:%d] (%s) ================================================\n", __FILE__, __LINE__, __FUNCTION__);
      return x;
    }
  }

  if (auto func = dyn_cast<AbstractFunctionDecl>(requirement)) {
    auto baseName = func->getBaseName();
    auto argumentNames = func->getName().getArgumentNames();

    // === _mapStorage(keyPath:)
    if (func->isStatic() && baseName == Context.Id_mapStorage &&
        argumentNames.size() == 1 &&
        argumentNames[0] == Context.Id_keyPath) {
      auto x = deriveDistributedActorFuncMapStorage(*this);
      fprintf(stderr, "[%s:%d] (%s) ================================================\n", __FILE__, __LINE__, __FUNCTION__);
      this->Nominal->dump();
      fprintf(stderr, "[%s:%d] (%s) ================================================\n", __FILE__, __LINE__, __FUNCTION__);
      return x;
    }
  }

  requirement->dump();
  assert(false && "Failed to derive (unknown?) distributed actor requirement.");
}


std::pair<Type, TypeDecl *>
DerivedConformance::deriveDistributedActorAssociatedType(AssociatedTypeDecl *assocType) {
  if (assocType->getName() == Context.Id_DistributedActorLocalStorage) {
    return deriveDistributedActorLocalStorageStruct(*this);
  }

  assocType->dump();
  assert(false && "Failed to derive (unknown?) distributed actor associated type requirement.");
}
