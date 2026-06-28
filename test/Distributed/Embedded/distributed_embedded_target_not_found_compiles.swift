// RUN: %target-swift-frontend -typecheck -enable-experimental-feature Embedded -parse-as-library -wmo -target %target-cpu-apple-macos14 %s

// REQUIRES: swift_in_compiler
// REQUIRES: OS=macosx
// REQUIRES: swift_feature_Embedded

// `EmbeddedDistributedTargetNotFound` is part of the receiver-side
// dispatch surface that distributed actor systems use in their receive
// code paths under Embedded. It does not require any conformance machinery
// beyond `Error`; verify it builds in user code.

import _Concurrency
import Distributed

func throwsIfMissing(_ target: String) throws {
  throw EmbeddedDistributedTargetNotFound(target: target)
}
