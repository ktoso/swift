// Bad value for -distributed-id-gen= is rejected.
// RUN: not %target-swift-frontend -typecheck -distributed-id-gen=sha256 -parse-as-library %s 2>&1 | %FileCheck --check-prefix=BADVALUE %s

// -distributed-id-gen=fnv1a-64 is Embedded-only; requesting it without Embedded
// is an error rather than being silently ignored.
// RUN: not %target-swift-frontend -typecheck -distributed-id-gen=fnv1a-64 -parse-as-library %s 2>&1 | %FileCheck --check-prefix=NOEMBEDDED %s

// BADVALUE: invalid value 'sha256' in '-distributed-id-gen=sha256'
// NOEMBEDDED: distributed actor ID generation strategy 'fnv1a-64' is only supported in Embedded Swift

public func f() {}
