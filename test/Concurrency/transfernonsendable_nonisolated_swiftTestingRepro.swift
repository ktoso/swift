// RUN: %target-swift-frontend -emit-sil -strict-concurrency=complete -target %target-swift-5.1-abi-triple -verify -verify-additional-prefix without-noniso-nonsend-default- %s -o /dev/null -enable-upcoming-feature GlobalActorIsolatedTypesUsability
// RUN: %target-swift-frontend -emit-sil -strict-concurrency=complete -target %target-swift-5.1-abi-triple -verify -verify-additional-prefix ni-ns- %s -o /dev/null -enable-upcoming-feature GlobalActorIsolatedTypesUsability -enable-upcoming-feature NonisolatedNonsendingByDefault

// REQUIRES: concurrency
// REQUIRES: swift_feature_GlobalActorIsolatedTypesUsability
// REQUIRES: swift_feature_NonisolatedNonsendingByDefault

// Reproduces issue uncovered in swift-testing which is preventing nonsending
// adoption in task local APIs but is a general issue.
//
// TaskLocal.withValue is nonisolated(nonsending), so its closure inherits the
// caller's isolation. When the caller is @concurrent (nonisolated), the closure
// effectively runs in nonisolated context. Passing a captured value to another
// @concurrent function should not be flagged as a send across isolation domains.
//
// With NonisolatedNonsendingByDefault, withCancellationHandling also
// becomes nonisolated(nonsending), so no send occurs and no diagnostic.

struct MyTest: Sendable {
  fileprivate static let _taskLocal: TaskLocal<MyTest?>! = nil
}
func withCancellationHandling<R>(_ body: () async throws -> R) async rethrows -> R {
  try await body()
}

extension MyTest {
  static func withCurrent<R>(perform body: () async throws -> R) async rethrows -> R {
    return try await MyTest._taskLocal.withValue(nil) {
      try await withCancellationHandling(body)
    }
  }
}
