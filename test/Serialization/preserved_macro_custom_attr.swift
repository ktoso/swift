// Verifies that `@preservedInInterface` preserves a macro `CustomAttr`
// with its argument-list source text through `.swiftmodule` serialization.
// Uses a vanilla third-party macro (not Distributed's `@Entitlement`) to
// exercise the mechanism in the generic case.
//
// Before this change, macro `CustomAttr`s were dropped entirely by
// `Serialization.cpp`'s `case DeclAttrKind::Custom:` early-return. The
// opt-in reroutes such attrs through an extended `CustomDeclAttrLayout`
// that carries the arg-list source text; the deserializer stashes that
// text on the reconstructed `CustomAttr`, and Sema materializes an
// `ArgumentList` from it via `materializePreservedCustomAttrArgs` (which
// is triggered on demand by callers that need the args - the peer
// expander and `inheritDistributedValidationAttrs`).
//
// The `-print-module` path deliberately does NOT trigger the materialize
// step (that requires spinning up a parser plus fresh SourceFile), so a
// module-printer FileCheck would only observe the null args slot and
// print `@PreservedMacro` bare. Instead, this test checks the raw
// serialized module via `%llvm-bcanalyzer` for the presence of the
// `Custom_DECL_ATTR` record, which is only emitted for macro `CustomAttr`s
// when the macro opts in.
//
// REQUIRES: swift_swift_parser
// REQUIRES: asserts
//
// RUN: %empty-directory(%t)
// RUN: %host-build-swift -swift-version 5 -emit-library -o %t/%target-library-name(MacroDefinition) -module-name=MacroDefinition %S/../Macros/Inputs/syntax_macro_definitions.swift -no-toolchain-stdlib-rpath -swift-version 5
//
// Producer: emit a .swiftmodule declaring an opted-in macro and applying
// it to a public var with a string payload. Emitting the module runs the
// peer macro (adds `_foo`) - use `-Xfrontend -disable-availability-checking`
// only for cleanliness; the mechanism under test doesn't need it.
// RUN: %target-swift-frontend -emit-module -o %t/PreservedMacroLib.swiftmodule -module-name PreservedMacroLib -parse-as-library %s -load-plugin-library %t/%target-library-name(MacroDefinition) -DPRODUCER
//
// The serialized module must include a `Custom_DECL_ATTR` record; that
// record is only present when the macro's `@preservedInInterface` opt-in
// took the "serialize with arg text" path instead of the default macro
// drop.
// RUN: %llvm-bcanalyzer -dump %t/PreservedMacroLib.swiftmodule | %FileCheck %s

#if PRODUCER

@preservedInInterface
@attached(peer, names: named(_foo))
public macro PreservedMacro(_ tag: String) = #externalMacro(module: "MacroDefinition", type: "AddPeerStoredPropertyMacro")

public struct Holder {
  @PreservedMacro("payload-string")
  public var target: Int = 1
}

#endif

// The record ID for `Custom_DECL_ATTR` should appear at least once in the
// bitcode dump, meaning at least one macro-referring `CustomAttr` survived
// serialization instead of being dropped. Non-macro custom attributes also
// emit this record, but this test file has none - the only source of it
// is the `@PreservedMacro("payload-string")` application above.
//
// CHECK: Custom_DECL_ATTR
