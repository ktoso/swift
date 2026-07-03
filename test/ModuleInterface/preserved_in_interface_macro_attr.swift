// REQUIRES: asserts
// REQUIRES: swift_swift_parser

// Verifies the `@preservedInInterface` opt-in on macro declarations.
//
// - A macro attribute is stripped from the emitted `.swiftinterface` by
//   default (Options.SuppressExpandedMacros).
// - Marking the macro declaration with `@preservedInInterface` overrides
//   the strip and additionally forces the CustomAttr's argument list to
//   render (which the interface printer otherwise skips because
//   Options.PrintExprs is off in interface mode).
//
// The mechanism is opt-in per macro: any macro can request the behavior,
// no per-feature name allow-list in the printer.

// RUN: %empty-directory(%t)
// RUN: %host-build-swift -swift-version 5 -emit-library -o %t/%target-library-name(MacroDefinition) -module-name=MacroDefinition %S/../Macros/Inputs/syntax_macro_definitions.swift -no-toolchain-stdlib-rpath -swift-version 5
//
// RUN: %target-swift-emit-module-interface(%t/PreservedTest.swiftinterface) -module-name PreservedTest %s -load-plugin-library %t/%target-library-name(MacroDefinition)
// RUN: %FileCheck %s < %t/PreservedTest.swiftinterface --check-prefix CHECK
//
// Note: no `-compile-module-from-interface` round-trip step: preserving the
// macro attribute in the interface means the interface contains both the
// attribute AND the peer decls the macro already emitted, so re-parsing
// would re-expand the macro and produce a peer-decl collision. That's a
// legitimate consequence of the "preserve attribute" opt-in and orthogonal
// to what this test verifies. The Distributed use case (an @Entitlement
// on a protocol requirement, expanded to nothing at the requirement site)
// doesn't hit this because the macro emits no peers at the marked scope.

// The two macro declarations themselves both appear in the interface (as
// normal for public macro decls). The `@preservedInInterface` attribute
// on `Preserved` also survives.
//
// CHECK: @preservedInInterface @attached(peer, names: named(_foo)) public macro Preserved(_ tag: Swift::String)
@preservedInInterface
@attached(peer, names: named(_foo))
public macro Preserved(_ tag: String) = #externalMacro(module: "MacroDefinition", type: "AddPeerStoredPropertyMacro")

// Sibling macro without the opt-in: shows up in the interface normally
// (as any public macro decl does), but ATTRIBUTE-USAGE sites of it (below)
// have the attribute stripped.
//
// CHECK: @attached(peer, names: named(_foo)) public macro Unpreserved(_ tag: Swift::String)
@attached(peer, names: named(_foo))
public macro Unpreserved(_ tag: String) = #externalMacro(module: "MacroDefinition", type: "AddPeerStoredPropertyMacro")

// The @Preserved attribute on `preservedTarget` MUST appear in the
// interface with its full argument list (`"preserved-payload"`).
//
// CHECK: struct PreservedHolder
public struct PreservedHolder {
  // CHECK: @Preserved("preserved-payload") public var preservedTarget
  @Preserved("preserved-payload")
  public var preservedTarget: Int = 1
}

// The @Unpreserved attribute on `unpreservedTarget` MUST NOT appear in the
// interface; it's a plain macro CustomAttr, filtered out by default.
//
// CHECK: struct UnpreservedHolder
public struct UnpreservedHolder {
  // CHECK-NOT: @Unpreserved
  // CHECK: public var unpreservedTarget
  @Unpreserved("unpreserved-payload")
  public var unpreservedTarget: Int = 2
}
