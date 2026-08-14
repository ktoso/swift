# Distributed

Build systems that run distributed code across multiple processes and devices.

Distributed actors share many characteristics with Swift actors,
and include additional isolation checks to ensure
location transparency and safety in a distributed environment.
Similar to how actors make it easier to write concurrent code
that's safe and correct to run on a single computer,
distributed actors make it easier to write code
that runs across multiple computers.

![A diagram showing two columns of actors. The left column includes a remote actor reference. The right column includes a local distributed actor. An arrow points from the remote actor reference to the local distributed actor that it refers to.](distributed-module)

You use three main parts when writing code with distributed actors:

- Swift language support for distributed actors and for building distributed or RPC systems integrated into the language.
  For more information,
  see [Concurrency][concurrency] in [The Swift Programming Language][tspl].

- The Distributed module, which includes the types and protocols you need
  to declare and use distributed actors.
  For example, it has
  protocols to which distributed actors and distributed actor systems conform,
  and structures that encapsulate information about calls to a distributed actor.

- A *distributed actor system* provides an implementation of the
  ``Distributed/DistributedActorSystem`` protocol
  and coordinates between the cluster's nodes.
  A distributed actor is always part of some distributed actor system;
  that distributed actor system handles the serialization and networking
  necessary to perform remote method calls.
  For local testing, you can use ``Distributed/LocalTestingDistributedActorSystem``.
  For production,
  you can use `ClusterSystem` offered by
  the [Swift Distributed Actors][cluster] library,
  use another library,
  or [write your own distributed actor system](<doc:implementing-a-custom-distributed-actor-system>).

## Remote Call Semantics

By default, every remote call made on a distributed actor follows a
request/response pattern: the caller `await`s a reply from the peer, and the
actor system's `remoteCall` / `remoteCallVoid` implementation is responsible
for shipping the invocation over the network, awaiting the peer's response,
and delivering the returned value or thrown error back to the caller.

Some transports (particularly synchronous IPC or classical actor-model style
messaging) benefit from opting out of parts of that pattern. The
`@remoteCall(...)` attribute is a *hint* the compiler carries from the
declaration site through the synthesized thunk into
``Distributed/RemoteCallTarget``, so the actor system can decide whether to
take an alternative code path.

The attribute has no effect on local calls; it only influences the remote
branch of the synthesized thunk. Individual actor systems are free to ignore
the hint entirely.

Both variants are experimental and gated by
`-enable-experimental-feature DistributedRemoteCallSemantics`.

### `@remoteCall(blocking)`

A blocking remote call asks the actor system to perform the request/response
using a synchronous, blocking form of IPC. It is intended for IPC transports
where a synchronous path is significantly cheaper than an asynchronous one
(for example, XPC synchronous messaging), and where blocking the caller's
thread is an acceptable trade for the reduced overhead.

The distributed method itself may still be declared `async`; the attribute
changes only how the remote IPC is performed, not the method's own effects.

The actor system observes the hint via
``Distributed/RemoteCallTarget/isSynchronousBlockingRemoteCall`` inside its
`remoteCall` / `remoteCallVoid` implementation and selects a blocking IPC
path when the flag is set.

Blocking calls should be used sparingly: blocking the calling thread rather
than suspending the task can lead to thread starvation of the global
concurrency pool. Prefer the default (fully asynchronous) form whenever the
performance win of blocking IPC is not clearly justified.

### `@remoteCall(oneway)`

A oneway remote call is fire-and-forget: the actor system may complete the
local side of the call as soon as the outgoing message has been written, and
should not wait for a peer reply. This matches the "message" concept of
classical actor systems, and is well suited to keep-alive messages, batched
acknowledgements, and other traffic where a response would only be discarded.

Oneway calls are still `async throws`. The synthesized thunk still invokes
`try await remoteCallVoid(...)`, so the actor system is allowed to suspend
the caller until the outbound write completes and to throw on send failure.
The contract is only that it must not depend on a reply from the peer.

Only `Void`-returning distributed functions may be declared
`@remoteCall(oneway)`; the compiler rejects non-`Void` functions and computed
properties at the declaration site.

The actor system observes the hint via
``Distributed/RemoteCallTarget/isOnewayRemoteCall`` inside its
`remoteCallVoid` implementation.

'blocking' and 'oneway' are mutually exclusive on a single declaration: a
call that discards its reply cannot also be a synchronous request/response.
The compiler diagnoses `@remoteCall(blocking, oneway)` as an illegal
combination.

[concurrency]: https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html
[tspl]: https://docs.swift.org/swift-book/
[cluster]: https://github.com/apple/swift-distributed-actors/

## Topics

### Distributed actors

- ``Distributed/DistributedActor``
- ``Distributed/Resolvable()``
- ``Distributed/buildDefaultDistributedRemoteActorExecutor(_:)``

### Distributed actor system

- <doc:implementing-a-custom-distributed-actor-system>
- ``Distributed/DistributedActorSystem``
- ``Distributed/RemoteCallTarget``
- ``Distributed/RemoteCallTarget/isSynchronousBlockingRemoteCall``
- ``Distributed/RemoteCallTarget/isOnewayRemoteCall``
- ``Distributed/RemoteCallArgument``
- ``Distributed/DistributedTargetInvocationEncoder``
- ``Distributed/DistributedTargetInvocationDecoder``
- ``Distributed/DistributedTargetInvocationResultHandler``


### Local testing

- ``Distributed/LocalTestingDistributedActorSystem``
- ``Distributed/LocalTestingActorID``
- ``Distributed/LocalTestingActorAddress``
- ``Distributed/LocalTestingInvocationEncoder``
- ``Distributed/LocalTestingInvocationDecoder``
- ``Distributed/LocalTestingInvocationResultHandler``

### Errors

- ``Distributed/DistributedActorCodingError``
- ``Distributed/DistributedActorSystemError``
- ``Distributed/ExecuteDistributedTargetError``
- ``Distributed/LocalTestingDistributedActorSystemError``
