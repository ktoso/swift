// Verifies that `@preservedInInterface` is rejected when attached to
// anything other than a macro declaration. The rejection comes for free
// from the `OnMacro` requirement in the DeclAttr.def entry; no custom
// diagnostic logic is needed.

// RUN: %target-typecheck-verify-swift

@preservedInInterface // expected-error {{'@preservedInInterface' attribute cannot be applied to this declaration}}
public func plainFunc() {}

@preservedInInterface // expected-error {{'@preservedInInterface' attribute cannot be applied to this declaration}}
public struct PlainStruct {}

@preservedInInterface // expected-error {{'@preservedInInterface' attribute cannot be applied to this declaration}}
public class PlainClass {}

@preservedInInterface // expected-error {{'@preservedInInterface' attribute cannot be applied to this declaration}}
public enum PlainEnum {}

@preservedInInterface // expected-error {{'@preservedInInterface' attribute cannot be applied to this declaration}}
public protocol PlainProtocol {}

@preservedInInterface // expected-error {{'@preservedInInterface' attribute cannot be applied to this declaration}}
public var plainGlobal: Int = 0
