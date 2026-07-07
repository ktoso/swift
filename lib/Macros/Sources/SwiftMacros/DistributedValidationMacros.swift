//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//
//
// Implements the @Entitlement and @ValidateRemoteCall attached peer macros.
//
// Each attached macro emits ONE peer declaration next to the target
// distributed func/var: an accessor function that, on demand, materializes a
// `RemoteCallValidator` (wrapping an entitlement policy or a custom validator)
// into the caller-provided out-parameter. Strings and other
// non-const-expressible Swift values live inside this function body; SE-0492's
// constant-expression rule does not apply to normal function bodies.
//
// The `swift5_daval` section record that identifies the target and points at
// this accessor is NOT emitted here - the compiler (IRGen) emits it, in
// `emitDistributedTargetAccessor` (lib/IRGen/GenDistributed.cpp), next to the
// target's accessible-function record. IRGen emits the record rather than the
// macro because the record's identity is the target's full mangled
// distributed-thunk name (collision-free, and stored once by sharing the exact
// string the accessible-function record already carries), and a macro can
// express neither a pointer in a `@section` constant (SE-0492) nor the mangled
// name.
//
// See swiftlang/swift-testing's Documentation/ABI/TestContent.md for the ABI
// pattern this file follows.
//
//===----------------------------------------------------------------------===//

import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics
import SwiftSyntaxBuilder

// ==== -----------------------------------------------------------------------
// MARK: @Entitlement

public struct EntitlementMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    let target = try diagnoseAttachmentSite(
      attributeName: "@Entitlement",
      node: node,
      declaration: declaration)

    // Skip peer emission on protocol requirements. The attribute serves as a
    // marker there; the compiler clones it onto the witness during
    // conformance checking (see `matchWitnessDistributedValidationAttrs` in
    // `lib/Sema/TypeCheckProtocol.cpp`), where the macro re-expands and
    // emits the section record against the concrete member.
    if isProtocolRequirementContext(context) {
      return []
    }

    let targetName = target.name.text
    let policyExpression = entitlementPolicyExpression(from: node)
    // `@Entitlement` maps onto a `RemoteCallValidator` whose closure
    // evaluates the entitlement policy against the receive-side task-local
    // entitlement set.
    let validatorExpression =
      """
      Distributed.RemoteCallValidator({
          try Distributed.DistributedValidation.evaluate(\(policyExpression))
        })
      """
    return emitValidationPeers(
      targetName: targetName,
      validatorExpression: validatorExpression,
      in: context)
  }
}

// ==== -----------------------------------------------------------------------
// MARK: @ValidateRemoteCall

public struct ValidateRemoteCallMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    let target = try diagnoseAttachmentSite(
      attributeName: "@ValidateRemoteCall",
      node: node,
      declaration: declaration)

    // Skip peer emission on protocol requirements. The attribute is a
    // marker inherited onto witnesses by the compiler; peer expansion
    // runs on the concrete method there.
    if isProtocolRequirementContext(context) {
      // But diagnose the closure-body form here: on cross-module inheritance
      // the closure text is preserved via `@preservedInInterface` and
      // re-parsed at the witness site. The parsed `ClosureExpr` carries a
      // stale parent DeclContext that trips a compiler assertion in
      // `PreCheckTarget::walkToClosureExprPre`. The pattern is safe only for
      // named-factory references (`@ValidateRemoteCall(.myValidator)`),
      // which don't require preserving an inline expression tree.
      if let arguments = node.arguments?.as(LabeledExprListSyntax.self),
         let first = arguments.first,
         first.expression.is(ClosureExprSyntax.self) {
        throw closureOnProtocolRequirement(node: node)
      }
      return []
    }

    let targetName = target.name.text
    let argExpression = customValidatorExpression(from: node)
    // Wrap through `RemoteCallValidator(...)` so both macro overloads
    // (the closure-taking one and the `RemoteCallValidator`-taking one)
    // funnel through a single emission path. The pass-through init handles
    // the copy case; the closure init handles the closure case.
    let validatorExpression =
      "Distributed.RemoteCallValidator(\(argExpression))"
    return emitValidationPeers(
      targetName: targetName,
      validatorExpression: validatorExpression,
      in: context)
  }
}

// ==== -----------------------------------------------------------------------
// MARK: Marker generator (attached to a validation-macro declaration)
//
// A peer macro attached to a `macro` declaration that generates a marker type
// `<MacroName>Macro` conforming to `DistributedRemoteCallValidationMacroIdentifier`. An actor system
// lists such marker types in `DistributedRemoteCallValidation.InheritMacros<...>`
// to opt into inheriting the corresponding validation macro from protocol
// requirements onto its actors' witnesses; the compiler recovers the macro
// identity by stripping the `Macro` suffix from the marker type name.

public struct RemoteCallValidationMarkerMacro: PeerMacro {
  /// Attributes copied verbatim from the attached macro declaration onto the
  /// generated marker type, so the marker matches the macro's availability and
  /// SPI. Mirrors `DistributedResolvableMacro.attributesToCopy`.
  static let attributesToCopy: [String] = [
    "available",
    "_spi",
    "_spi_available",
  ]

  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard let macroDecl = declaration.as(MacroDeclSyntax.self) else {
      // Only meaningful on a `macro` declaration; no-op elsewhere.
      return []
    }
    let markerName = "\(macroDecl.name.text)Macro"
    // Copy availability (and SPI) from the macro being marked so the generated
    // marker type is usable in exactly the same contexts as the macro itself.
    let attributes = macroDecl.attributes.filter { attr in
      Self.attributesToCopy.contains(
        attr.as(AttributeSyntax.self)?.attributeName.trimmed.description ?? "")
    }
    return [
      """
      \(attributes)
      public enum \(raw: markerName): Distributed.DistributedRemoteCallValidationMacroIdentifier {}
      """
    ]
  }
}

// ==== -----------------------------------------------------------------------
// MARK: Peer emission

/// Emits the validation accessor for a single @Entitlement /
/// @ValidateRemoteCall attachment. The accessor is a **literal closure**
/// coerced to `_DistributedValidationAccessor` (SE-0492 permits captureless
/// closures as constant expressions; a coerced-to-`@convention(c)`
/// static-method reference does NOT coerce, hence a closure).
///
/// The identifying `swift5_daval` record is emitted by IRGen, not here (see
/// this file's header). IRGen relative-points that record at the accessor
/// emitted by this function.
///
/// - Parameter validatorExpression: a Swift expression (as source text) that
///   constructs the `RemoteCallValidator` value the accessor should return.
///   Strings, closures, and arbitrary Swift expressions are all fine here
///   because the accessor body is a normal Swift function context.
private func emitValidationPeers(
  targetName: String,
  validatorExpression: String,
  in context: some MacroExpansionContext
) -> [DeclSyntax] {
  // The accessor name is compiler-issued via `makeUniqueName`. Multiple
  // attributes on the same distributed member (`@Entitlement("a");
  // @Entitlement("b")`, or a witness-local attr + a protocol-inherited clone
  // of the same kind) each invoke this function, so the name must be unique
  // per expansion to avoid an "invalid redeclaration" error. IRGen finds the
  // accessors by walking the target's peer declarations (not by name), and
  // emits one record per accessor; the runtime composes them AllOf.
  let accessorName = context.makeUniqueName(
    "__daval_\(sanitizeIdentifier(targetName))_accessor")

  // The accessor lives in its own section so `@section` guarantees SE-0492
  // static initialization: the captureless closure is lowered to a constant
  // C function pointer placed in the section at load time, which the record's
  // relative pointer resolves to. This section is never stride-walked - the
  // runtime reaches each accessor only through the relative pointer in its
  // `swift5_daval` record - so its layout is unconstrained.
  let accessorSectionAttrs: DeclSyntax =
    """
    #if objectFormat(MachO)
    @section("__DATA_CONST,__swift5_davala")
    #elseif objectFormat(ELF) || objectFormat(Wasm)
    @section("swift5_davala")
    #elseif objectFormat(COFF)
    @section(".sw5davala$B")
    #endif
    @used
    """

  let accessor: DeclSyntax =
    """
    \(accessorSectionAttrs)
    @available(*, deprecated, message: "Implementation detail of Distributed. Do not use directly.")
    private static let \(accessorName): Distributed._DistributedValidationAccessor = { outValue, type, hint, reserved in
        let validator: Distributed.RemoteCallValidator = \(raw: validatorExpression)
        outValue.assumingMemoryBound(to: Distributed.RemoteCallValidator.self)
          .initialize(to: validator)
        return true
      }
    """
  return [accessor]
}

/// Reduces a Swift identifier to characters safe for compositing into another
/// identifier. Operators and other odd characters get replaced by `_`.
private func sanitizeIdentifier(_ name: String) -> String {
  String(name.map { ch in
    if ch.isLetter || ch.isNumber || ch == "_" { return ch }
    return "_"
  })
}

// ==== -----------------------------------------------------------------------
// MARK: Argument extraction

/// Extracts the argument expression from `@Entitlement("...")` or
/// `@Entitlement(<policy>)` and returns Swift source text that constructs a
/// `EntitlementPolicy`. The single-string form is sugar for
/// `.entitlement("...")`.
private func entitlementPolicyExpression(from node: AttributeSyntax) -> String {
  guard let arguments = node.arguments?.as(LabeledExprListSyntax.self),
    let first = arguments.first
  else {
    // Should not happen for a well-formed `@Entitlement(...)` - the compiler
    // would have rejected the attribute before invoking the macro. Emit a
    // placeholder that keeps the generated code well-formed.
    return #"Distributed.EntitlementPolicy.entitlement("")"#
  }

  let argText = first.expression.trimmedDescription

  if first.expression.is(StringLiteralExprSyntax.self) {
    return "Distributed.EntitlementPolicy.entitlement(\(argText))"
  }

  // Anything else is either an explicit `.entitlement(...)`, `.anyOf(...)`,
  // `.allOf(...)`, or an already-typed `EntitlementPolicy` value. Wrap so
  // implicit-member syntax (`.anyOf(...)`) resolves against the enum type.
  return "(\(argText)) as Distributed.EntitlementPolicy"
}

/// Extracts the validator function-or-closure argument from
/// `@ValidateRemoteCall(<expr>)` and returns Swift source text usable as the
/// argument to `RemoteCallValidator(...)`.
private func customValidatorExpression(from node: AttributeSyntax) -> String {
  guard let arguments = node.arguments?.as(LabeledExprListSyntax.self),
    let first = arguments.first
  else {
    return "{ }"
  }
  return first.expression.trimmedDescription
}

// ==== -----------------------------------------------------------------------
// MARK: Attachment-site validity

private struct AttachmentTarget {
  var name: TokenSyntax
}

/// Returns the target's identifier token if `declaration` is a
/// `distributed func` or `distributed var` in a valid state for validation
/// attachment; otherwise throws a diagnostic pinned to `node`.
///
/// Two distinct diagnostics:
///   - "not a distributed func or var" - the annotated decl is a struct,
///     class, actor, enum, protocol, subscript, init, deinit, extension, or
///     anything else. No fixit.
///   - "missing `distributed` modifier" - the decl IS a plain func or var,
///     just missing the `distributed` modifier. Fixit inserts `distributed`.
private func diagnoseAttachmentSite(
  attributeName: String,
  node: AttributeSyntax,
  declaration: some DeclSyntaxProtocol
) throws -> AttachmentTarget {
  if let fn = declaration.as(FunctionDeclSyntax.self) {
    if !fn.modifiers.contains(where: { $0.name.text == "distributed" }) {
      throw missingDistributedModifier(
        attributeName: attributeName,
        node: node,
        modifiersOwner: Syntax(fn),
        currentModifiers: fn.modifiers,
        replaced: { newModifiers in Syntax(fn.with(\.modifiers, newModifiers)) })
    }
    return AttachmentTarget(name: fn.name)
  }

  if let variable = declaration.as(VariableDeclSyntax.self) {
    if !variable.modifiers.contains(where: { $0.name.text == "distributed" }) {
      throw missingDistributedModifier(
        attributeName: attributeName,
        node: node,
        modifiersOwner: Syntax(variable),
        currentModifiers: variable.modifiers,
        replaced: { newModifiers in Syntax(variable.with(\.modifiers, newModifiers)) })
    }
    let name = variable.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier
      ?? .identifier("unknown")
    return AttachmentTarget(name: name)
  }

  throw notDistributedFuncOrVar(
    attributeName: attributeName,
    node: node,
    declarationKind: describeKind(declaration))
}

private func describeKind(_ declaration: some DeclSyntaxProtocol) -> String {
  if declaration.isClass { return "class" }
  if declaration.isActor { return "actor" }
  if declaration.isStruct { return "struct" }
  if declaration.isEnum { return "enum" }
  if declaration.is(ProtocolDeclSyntax.self) { return "protocol" }
  if declaration.is(ExtensionDeclSyntax.self) { return "extension" }
  if declaration.is(InitializerDeclSyntax.self) { return "init" }
  if declaration.is(DeinitializerDeclSyntax.self) { return "deinit" }
  if declaration.is(SubscriptDeclSyntax.self) { return "subscript" }
  return "\(declaration.kind)"
}

// ==== -----------------------------------------------------------------------
// MARK: Diagnostics

struct DistributedValidationDiagnostic: DiagnosticMessage {
  enum ID: String {
    case notDistributedFuncOrVar = "not distributed func or var"
    case missingDistributedModifier = "missing distributed modifier"
    case closureOnProtocolRequirement = "closure on protocol requirement"
  }

  var message: String
  var diagnosticID: MessageID
  var severity: DiagnosticSeverity

  init(message: String, id: ID, severity: DiagnosticSeverity = .error) {
    self.message = message
    self.diagnosticID = MessageID(domain: "Distributed", id: id.rawValue)
    self.severity = severity
  }
}

struct DistributedValidationFixIt: FixItMessage {
  var message: String
  var fixItID: MessageID

  init(message: String, id: String) {
    self.message = message
    self.fixItID = MessageID(domain: "Distributed", id: id)
  }
}

private func notDistributedFuncOrVar(
  attributeName: String,
  node: AttributeSyntax,
  declarationKind: String
) -> DiagnosticsError {
  DiagnosticsError(diagnostics: [
    Diagnostic(
      node: Syntax(node),
      message: DistributedValidationDiagnostic(
        message:
          "'\(attributeName)' can only be applied to a 'distributed func' or 'distributed var', but was attached to '\(declarationKind)'",
        id: .notDistributedFuncOrVar))
  ])
}

private func missingDistributedModifier(
  attributeName: String,
  node: AttributeSyntax,
  modifiersOwner: Syntax,
  currentModifiers: DeclModifierListSyntax,
  replaced: (DeclModifierListSyntax) -> Syntax
) -> DiagnosticsError {
  let distributedModifier = DeclModifierSyntax(
    name: .keyword(.distributed, trailingTrivia: .space))

  // Prepend `distributed` to the existing modifier list. If the list is empty
  // the new modifier inherits the owner's leading trivia so we don't lose
  // indentation.
  var newModifiers = currentModifiers
  if newModifiers.isEmpty {
    var m = distributedModifier
    m.leadingTrivia = modifiersOwner.leadingTrivia
    newModifiers = DeclModifierListSyntax([m])
  } else {
    newModifiers = DeclModifierListSyntax([distributedModifier] + Array(currentModifiers))
  }

  let newOwner = replaced(newModifiers)

  let fixIt = FixIt(
    message: DistributedValidationFixIt(
      message: "Add 'distributed' modifier",
      id: "add-distributed-modifier"),
    changes: [.replace(oldNode: modifiersOwner, newNode: newOwner)])

  return DiagnosticsError(diagnostics: [
    Diagnostic(
      node: Syntax(node),
      message: DistributedValidationDiagnostic(
        message:
          "'\(attributeName)' can only be applied to a 'distributed func' or 'distributed var'; add the 'distributed' modifier or remove '\(attributeName)'",
        id: .missingDistributedModifier),
      fixIt: fixIt)
  ])
}

/// Emitted when `@ValidateRemoteCall({ ... })` is applied to a protocol
/// requirement. The closure body would be captured verbatim by
/// `@preservedInInterface` and re-parsed at each witness site during
/// cross-module inheritance. The parsed `ClosureExpr` carries a stale parent
/// `DeclContext` that trips the compiler's `PreCheckTarget` invariant. Named
/// factory references (`@ValidateRemoteCall(.myValidator)`) are unaffected -
/// they don't require preserving an inline expression tree - so users can
/// factor the body into a static factory on `RemoteCallValidator`.
private func closureOnProtocolRequirement(
  node: AttributeSyntax
) -> DiagnosticsError {
  DiagnosticsError(diagnostics: [
    Diagnostic(
      node: Syntax(node),
      message: DistributedValidationDiagnostic(
        message:
          "'@ValidateRemoteCall' on a protocol requirement cannot take an inline closure; use a named 'RemoteCallValidator' factory (e.g. '@ValidateRemoteCall(.myValidator)') so the value can be referenced across modules",
        id: .closureOnProtocolRequirement))
  ])
}

// ==== -----------------------------------------------------------------------
// MARK: Lexical-context helpers

/// Returns true when the attached-macro's target is inside a protocol
/// declaration (i.e. the attribute is on a protocol requirement, not on a
/// concrete method of a distributed actor).
///
/// Protocol requirements don't produce section records themselves - the
/// compiler's conformance-checking clones allow-listed attributes onto the
/// concrete witnesses, where peer expansion then emits the accessor.
private func isProtocolRequirementContext(
  _ context: some MacroExpansionContext
) -> Bool {
  for parent in context.lexicalContext {
    if parent.is(ProtocolDeclSyntax.self) { return true }
    // A nominal type or extension found before any protocol means we're not
    // inside a protocol requirement even if a protocol appears higher up
    // (nested types etc.). Stop at the innermost nominal parent.
    if parent.is(ActorDeclSyntax.self) { return false }
    if parent.is(ClassDeclSyntax.self) { return false }
    if parent.is(StructDeclSyntax.self) { return false }
    if parent.is(EnumDeclSyntax.self) { return false }
    if parent.is(ExtensionDeclSyntax.self) { return false }
  }
  return false
}
