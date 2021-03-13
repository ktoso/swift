//===--- Actor.h - ABI structures for actors --------------------*- C++ -*-===//
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
// Swift ABI describing actors.
//
//===----------------------------------------------------------------------===//

#ifndef SWIFT_ABI_DISTRIBUTED_ACTOR_H
#define SWIFT_ABI_DISTRIBUTED_ACTOR_H

#include "swift/ABI/HeapObject.h"
#include "swift/ABI/MetadataValues.h"

namespace swift {

/// The distributed (remote) actor implementation.
/// The memory layout is finely managed to contain only the address, transport and storage.
class alignas(Alignment_DistributedActorProxy) DistributedRemoteActor
    : public HeapObject {
public:
  // These constructors do not initialize the actor instance, and the
  // destructor does not destroy the actor instance; you must call
  // swift_defaultActor_{initialize,destroy} yourself.
  constexpr DistributedRemoteActor(const HeapMetadata *metadata)
    : HeapObject(metadata), PrivateData{} {}

  constexpr DistributedRemoteActor(const HeapMetadata *metadata,
                         InlineRefCounts::Immortal_t immortal)
    : HeapObject(metadata, immortal), PrivateData{} {}

  void *PrivateData[NumWords_DistributedRemoteActor];
};

} // end namespace swift

#endif
