// RUN: %target-swift-frontend -typecheck -verify %s -disable-availability-checking

// REQUIRES: concurrency


class A {}
class B: A {}
func f(_ x: String) async -> String? { x }
func testAsyncExprWithoutAwait() async {
  async let result: B? = nil
  if let result {} // expected-error {{expression is 'async' but is not marked with 'await'}}{{none}}
  // expected-warning@-1 {{value 'result' was defined but never used; consider replacing with boolean test}}
  // expected-note@-2 {{reference to async let 'result' is 'async'}}
}
