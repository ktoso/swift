// RUN: %target-run-simple-swift( -Xfrontend -disable-availability-checking %import-libdispatch -parse-as-library )
// RUN: %target-run-simple-swift( -Xfrontend -disable-availability-checking %import-libdispatch -parse-as-library -enable-upcoming-feature NonisolatedNonsendingByDefault)

// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: concurrency_runtime
// REQUIRES: libdispatch
// REQUIRES: objc_interop
// REQUIRES: swift_feature_NonisolatedNonsendingByDefault

// UNSUPPORTED: back_deployment_runtime
// UNSUPPORTED: back_deploy_concurrency
// UNSUPPORTED: freestanding

// rdar://173468054
// When a @MainActor class conforms to an @objc protocol with async methods,
// the @objc thunk must hop to the main actor's executor.
// With NonisolatedNonsendingByDefault, the protocol requirement must NOT
// override the global actor isolation of the conforming class's witness.

import Foundation
import StdlibUnittest

@objc protocol Worker {
    func doWork() async
}

@MainActor
class MyWorker: NSObject, Worker {
    func doWork() async {
        MainActor.assertIsolated("Expected to be running on MainActor")
    }
}

@main struct Main {
    static func main() async {
        let worker = MyWorker()
        await worker.doWork()

        await Task.detached {
            await worker.doWork()
        }.value
    }
}
