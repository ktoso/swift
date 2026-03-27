// RUN: %target-swift-frontend(mock-sdk: %clang-importer-sdk) -Xllvm -sil-print-types -emit-silgen -target %target-swift-5.1-abi-triple %s -verify | %FileCheck --check-prefix=CHECK %s
// RUN: %target-swift-frontend(mock-sdk: %clang-importer-sdk) -enable-upcoming-feature NonisolatedNonsendingByDefault -Xllvm -sil-print-types -emit-silgen -target %target-swift-5.1-abi-triple %s -verify | %FileCheck --check-prefix=CHECK-NN %s

// REQUIRES: concurrency
// REQUIRES: objc_interop
// REQUIRES: swift_feature_NonisolatedNonsendingByDefault

// rdar://173468054
// When a @GlobalActor class conforms to an @objc protocol with async methods,
// the @objc thunk must hop to the global actor's executor. With
// NonisolatedNonsendingByDefault, the protocol requirement is implicitly
// CallerIsolationInheriting, but that should NOT override the global actor
// isolation of the conforming class's witness method.

import Foundation

@globalActor actor TestActor {
    static let shared = TestActor()
    private init() {}
}

@objc protocol Worker {
    func doWork() async
}

// ==== -----------------------------------------------------------------------
// MARK: GlobalActor class conforming to @objc protocol

@TestActor
class MyWorker: NSObject, @TestActor Worker {
    // The method itself must be global_actor isolated to TestActor,
    // NOT caller_isolation_inheriting.

    // MyWorker.doWork()
    // CHECK: // Isolation: global_actor. type: TestActor
    // CHECK-LABEL: sil hidden [ossa] @$s{{.*}}8MyWorkerC6doWorkyyYaF : $@convention(method) @async (@guaranteed MyWorker) -> ()
    // CHECK:   hop_to_executor {{%.*}} : $TestActor

    // CHECK-NN: // Isolation: global_actor. type: TestActor
    // CHECK-NN-LABEL: sil hidden [ossa] @$s{{.*}}8MyWorkerC6doWorkyyYaF : $@convention(method) @async (@guaranteed MyWorker) -> ()
    // CHECK-NN:   hop_to_executor {{%.*}} : $TestActor

    // The @objc async closure thunk must also hop to TestActor.

    // @objc closure #1 in MyWorker.doWork()
    // CHECK-LABEL: sil shared [thunk] [ossa] @$s{{.*}}8MyWorkerC6doWork{{.*}}U_To
    // CHECK:   hop_to_executor {{%.*}} : $TestActor

    // CHECK-NN-LABEL: sil shared [thunk] [ossa] @$s{{.*}}8MyWorkerC6doWork{{.*}}U_To
    // CHECK-NN:   hop_to_executor {{%.*}} : $TestActor

    func doWork() async {}
}

// ==== -----------------------------------------------------------------------
// MARK: Non-global-actor class conforming to @objc protocol

// A class without a global actor should get caller_isolation_inheriting
// with NonisolatedNonsendingByDefault, and nonisolated without it.
class PlainWorker: NSObject, Worker {
    // PlainWorker.doWork()
    // Without the flag, the method is nonisolated (unspecified).
    // CHECK: // Isolation: unspecified
    // CHECK-LABEL: sil hidden [ossa] @$s{{.*}}11PlainWorkerC6doWorkyyYaF : $@convention(method) @async (@guaranteed PlainWorker) -> ()

    // With the flag, the method should get caller_isolation_inheriting
    // from default inference (no global actor to inherit).
    // CHECK-NN: // Isolation: caller_isolation_inheriting
    // CHECK-NN-LABEL: sil hidden [ossa] @$s{{.*}}11PlainWorkerC6doWorkyyYaF : $@convention(method) @async (@sil_isolated @sil_implicit_leading_param @guaranteed Builtin.ImplicitActor, @guaranteed PlainWorker) -> ()

    func doWork() async {}
}
