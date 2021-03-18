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

// ==== ------------------------------------------------------------------------

// TODO: deduplicate with 'declareDerivedProperty' from DerivedConformance...
// FIXME: !!!!!!!!!!!!!!!!!!!!!
std::pair<VarDecl *, PatternBindingDecl *>
createStoredProperty(ValueDecl *parent, DeclContext *parentDC, ASTContext &ctx,
                     VarDecl::Introducer introducer, Identifier name,
                     Type propertyInterfaceType, Type propertyContextType,
                     bool isStatic, bool isFinal);


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
getBoundPersonalityStorageType(ASTContext &C, NominalTypeDecl *decl) {
  // === DistributedActorStorage<?>
  auto storageTypeDecl = C.getDistributedActorStorageDecl();

  // === locate the SYNTHESIZED: DistributedActorLocalStorage
  auto localStorageTypeDecls = decl->lookupDirect(DeclName(C.Id_DistributedActorLocalStorage));
//  if (localStorageTypeDecls.size() > 1) {
//    assert(false && "Only a single DistributedActorLocalStorage type may be declared!");
//  }
  StructDecl *localStorageDecl = nullptr;
  for (auto decl : localStorageTypeDecls) {
    fprintf(stderr, "\n");
    fprintf(stderr, "[%s:%d] (%s) DECL:\n", __FILE__, __LINE__, __FUNCTION__);
    decl->dump();
    fprintf(stderr, "\n");
    if (auto structDecl = dyn_cast<StructDecl>(decl)) {
      localStorageDecl = structDecl;
      break;
    }
  }
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

  auto boundStorageType = BoundGenericType::get(
      storageTypeDecl, /*Parent=*/Type(), {localStorageType});

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
  auto actorDecl = dyn_cast<ClassDecl>(derived.Nominal);
  assert(actorDecl->isDistributedActor());

  fprintf(stderr, "\n");
  actorDecl->dump();
  fprintf(stderr, "[%s:%d] (%s) SYNTH STORAGE FOR ^^^^^^\n", __FILE__, __LINE__, __FUNCTION__);

  auto &C = derived.Nominal->getASTContext();

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

  // mirror all stored properties from the 'distributed actor' to the storage struct.
  // This must not use 'getStoredProperties' as it would create a cycle.
  for (auto *member : actorDecl->getMembers()) {
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
      derived.getConformanceContext()->mapTypeIntoContext(storageDecl->getInterfaceType()),
      storageDecl
  );
}

/******************************************************************************/
/******************************** FUNCTIONS ***********************************/
/******************************************************************************/

static ValueDecl*
deriveDistributedActorFuncMapStorage(DerivedConformance &derived) {

  return nullptr;
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
        new (C) DistributedActorIndependentAttr(/*IsImplicit=*/true));


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
  auto actorDecl = dyn_cast<ClassDecl>(derived.Nominal);
  assert(actorDecl->isDistributedActor());

  auto &C = derived.Nominal->getASTContext();

  auto boundPersonalityType = getBoundPersonalityStorageType(C, actorDecl);

  VarDecl *propDecl;
  PatternBindingDecl *pbDecl;
  std::tie(propDecl, pbDecl) = createStoredProperty(
      actorDecl, actorDecl, C,
      VarDecl::Introducer::Let, C.Id_storage,
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
    if (name == Context.Id_actorAddress)
      return deriveDistributedActorPropertyAddress(*this);

    if (name == Context.Id_actorTransport)
      return deriveDistributedActorPropertyTransport(*this);

    if (name == Context.Id_storage)
      return deriveDistributedActorPropertyStorage(*this);
  }

  if (auto func = dyn_cast<AbstractFunctionDecl>(requirement)) {
    auto baseName = func->getBaseName();
    auto argumentNames = func->getName().getArgumentNames();

    // === _mapStorage(keyPath:)
    if (func->isStatic() && baseName == Context.Id_mapStorage &&
        argumentNames.size() == 1 &&
        argumentNames[0] == Context.Id_keyPath)
      return deriveDistributedActorFuncMapStorage(*this);
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
