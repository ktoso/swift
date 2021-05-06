// RUN: %target-typecheck-verify-swift -enable-experimental-distributed
// REQUIRES: concurrency
// REQUIRES: distributed

// UNSUPPORTED: use_os_stdlib
// UNSUPPORTED: back_deployment_runtime

actor SomeActor { }

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
distributed actor MissingImportDistributedActor_0 { } // expected-error{{'_Distributed' module not imported, required for 'distributed actor'}}
// expected-error@-1{{class 'MissingImportDistributedActor_0' has no initializers}}

let t: ActorTransport // expected-error{{cannot find type 'ActorTransport' in scope}}
let a: ActorAddress // expected-error{{cannot find type 'ActorAddress' in scope}}

