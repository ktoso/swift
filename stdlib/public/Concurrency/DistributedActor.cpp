///===--- Actor.cpp - Standard actor implementation ------------------------===///
///
/// This source file is part of the Swift.org open source project
///
/// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
/// Licensed under Apache License v2.0 with Runtime Library Exception
///
/// See https:///swift.org/LICENSE.txt for license information
/// See https:///swift.org/CONTRIBUTORS.txt for the list of Swift project authors
///
///===----------------------------------------------------------------------===///
///
/// The default actor implementation for Swift actors, plus related
/// routines such as generic executor enqueuing and switching.
///
///===----------------------------------------------------------------------===///

#include "swift/Runtime/Concurrency.h"

#include "swift/Runtime/Atomic.h"
#include "swift/Runtime/Casting.h"
#include "swift/ABI/DistributedActor.h"
#include "swift/ABI/Task.h"
#include "swift/ABI/Actor.h"
#include "llvm/ADT/PointerIntPair.h"
#include "TaskPrivate.h"

using namespace swift;

/*****************************************************************************/
/******************* DISTRIBUTED ACTOR IMPLEMENTATION ************************/
/*****************************************************************************/

namespace {

class DistributedRemoteActorImpl : public HeapObject {
};

} /// end anonymous namespace

// ==== ------------------------------------------------------------------------

static_assert(sizeof(DistributedRemoteActorImpl) <= sizeof(DistributedRemoteActor) &&
              alignof(DistributedRemoteActorImpl) <= alignof(DistributedRemoteActor),
              "DistributedActorImpl doesn't fit in DistributedActor");

static_assert(sizeof(DistributedRemoteActorImpl) <= sizeof(DefaultActor) &&
              alignof(DistributedRemoteActorImpl) <= alignof(DefaultActor),
              "DistributedActorImpl must be smaller or equal in size to DefaultActor");

// ==== ------------------------------------------------------------------------

static DistributedRemoteActorImpl *asImpl(DistributedRemoteActor *actor) {
  return reinterpret_cast<DistributedRemoteActorImpl*>(actor);
}

static DistributedRemoteActor *asAbstract(DistributedRemoteActorImpl *actor) {
  return reinterpret_cast<DistributedRemoteActor*>(actor);
}

/*****************************************************************************/
/*********************** DEFAULT ACTOR IMPLEMENTATION ************************/
/*****************************************************************************/
