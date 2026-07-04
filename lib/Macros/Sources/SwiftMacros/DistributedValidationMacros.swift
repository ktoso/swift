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
// Each attached macro emits two peer declarations next to the target
// distributed func/var:
//
//   1. An accessor function that, on demand, materializes a
//      `EntitlementPolicy` (or a validator closure) into the caller-provided
//      out-parameter. Strings and other non-const-expressible Swift values
//      live inside this function body; SE-0492's constant-expression rule
//      does not apply to normal function bodies.
//
//   2. A section-placed record tuple in `swift5_daval` (Mach-O:
//      `__DATA_CONST,__swift5_daval`; ELF/Wasm: `swift5_daval`; COFF:
//      `.sw5daval$B`), marked `@used`, whose fields (kind FourCC, hash
//      literals, direct func-ref to the accessor) are all permitted SE-0492
//      constant expressions.
//
// See ~/code/swift-testing/Documentation/ABI/TestContent.md for the ABI
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
      enclosingTypeName: enclosingTypeName(from: context),
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
      enclosingTypeName: enclosingTypeName(from: context),
      targetName: targetName,
      validatorExpression: validatorExpression,
      in: context)
  }
}

// ==== -----------------------------------------------------------------------
// MARK: Peer emission

/// Emits the section-placed record for a single @Entitlement /
/// @ValidateRemoteCall attachment. The record's `accessor` field is a
/// **literal closure** (SE-0492 permits closures with no captures as
/// constant expressions; a coerced-to-`@convention(c)` static-method
/// reference does NOT coerce, hence a closure).
///
/// - Parameter validatorExpression: a Swift expression (as source text) that
///   constructs the `RemoteCallValidator` value the accessor should return.
///   Strings, closures, and arbitrary Swift expressions are all fine here
///   because the accessor body is a normal Swift function context.
private func emitValidationPeers(
  enclosingTypeName: String,
  targetName: String,
  validatorExpression: String,
  in context: some MacroExpansionContext
) -> [DeclSyntax] {
  // A single section-placed static record per attachment. Multiple attributes
  // on the same distributed member (`@Entitlement("a"); @Entitlement("b")`,
  // or a witness-local attr + a protocol-inherited clone of the same kind)
  // each invoke this function, so the record name must be unique per
  // expansion to avoid an "invalid redeclaration of '__daval_..._record'"
  // error. `makeUniqueName` seeds the shared prefix into a compiler-issued
  // fresh identifier. The runtime finds matching records by
  // `(actorTypeID, methodID)` hash on the record fields, not by symbol name,
  // so the name uniqueness is invisible to lookup.
  let recordName = context.makeUniqueName(
    "__daval_\(sanitizeIdentifier(targetName))_record")

  // FNV-1a-64 of the enclosing type's simple name and the target's simple
  // name. These are the on-disk ABI identifiers; the runtime hashes
  // `_mangledTypeName(Act.self)` and `RemoteCallTarget.identifier` the same
  // way at receive time. Simple names are a v1 approximation; a
  // follow-up will switch to full mangled names for uniqueness under
  // overloading and namespacing.
  let actorTypeIDLiteral = hexLiteral(fnv1a64(of: enclosingTypeName))
  let methodIDLiteral = hexLiteral(fnv1a64(of: targetName))

  let sectionAttrs: DeclSyntax =
    """
    #if objectFormat(MachO)
    @section("__DATA_CONST,__swift5_daval")
    #elseif objectFormat(ELF) || objectFormat(Wasm)
    @section("swift5_daval")
    #elseif objectFormat(COFF)
    @section(".sw5daval$B")
    #endif
    @used
    """

  // Record fields must be permitted SE-0492 constant expressions:
  //   - integer literals (kind, reserved1, actorTypeID, methodID)
  //   - a literal closure with no captures (the accessor)
  let record: DeclSyntax =
    """
    \(sectionAttrs)
    @available(*, deprecated, message: "Implementation detail of Distributed. Do not use directly.")
    private static let \(recordName): Distributed._DistributedValidationRecord = (
      0x6476616c,
      0,
      { outValue, type, hint, reserved in
        let validator: Distributed.RemoteCallValidator = \(raw: validatorExpression)
        outValue.assumingMemoryBound(to: Distributed.RemoteCallValidator.self)
          .initialize(to: validator)
        return true
      },
      \(raw: actorTypeIDLiteral),
      \(raw: methodIDLiteral)
    )
    """

  return [record]
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
/// argument to `EntitlementPolicy.custom(...)`.
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
///   - "not a distributed func or var" — the annotated decl is a struct,
///     class, actor, enum, protocol, subscript, init, deinit, extension, or
///     anything else. No fixit.
///   - "missing `distributed` modifier" — the decl IS a plain func or var,
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
// MARK: Identity hashing

/// Extracts the simple name of the enclosing nominal type from the macro's
/// lexical context. Since `@Entitlement`/`@ValidateRemoteCall` may only be
/// applied to members of a distributed actor, the immediate lexical parent
/// is always a nominal type. Returns an empty string if no enclosing type is
/// found (should not happen in valid code; used as a defensive default).
private func enclosingTypeName(from context: some MacroExpansionContext) -> String {
  for parent in context.lexicalContext {
    if let d = parent.as(ActorDeclSyntax.self) { return d.name.text }
    if let d = parent.as(ClassDeclSyntax.self) { return d.name.text }
    if let d = parent.as(StructDeclSyntax.self) { return d.name.text }
    if let d = parent.as(EnumDeclSyntax.self) { return d.name.text }
    if let d = parent.as(ProtocolDeclSyntax.self) { return d.name.text }
    if let e = parent.as(ExtensionDeclSyntax.self) {
      return e.extendedType.trimmedDescription
    }
  }
  return ""
}

/// Returns true when the attached-macro's target is inside a protocol
/// declaration (i.e. the attribute is on a protocol requirement, not on a
/// concrete method of a distributed actor).
///
/// Protocol requirements don't produce section records themselves — the
/// compiler's conformance-checking clones allow-listed attributes onto the
/// concrete witnesses, where peer expansion then emits the record.
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

/// FNV-1a-64 of the UTF-8 bytes of a string. This is the ABI-committed hash
/// function for `actorTypeID` and `methodID` in the `swift5_daval` section
/// records. Small, deterministic, distinct implementations in the plugin
/// (macro-expansion time) and the runtime must agree exactly, so keep this
/// unchanged once the ABI ships.
///
/// PAIRED IMPLEMENTATION: must remain byte-identical to
/// `DistributedValidation.fnv1a64(of:)` in
/// `stdlib/public/Distributed/DistributedValidation.swift`.
/// Drift is caught by
/// `test/Distributed/Runtime/distributed_validation_hash_stability.swift`
/// (golden-vector runtime test) and by the hex literals in
/// `test/Distributed/Macros/distributed_macro_validation_expansion.swift`
/// (macro-expansion CHECK lines).
private func fnv1a64(of s: String) -> UInt64 {
  var hash: UInt64 = 0xcbf29ce484222325 // FNV-1a-64 offset basis
  for byte in s.utf8 {
    hash ^= UInt64(byte)
    hash &*= 0x100000001b3         // FNV-1a-64 prime, wrapping multiply
  }
  return hash
}

/// Formats a UInt64 as a fixed-width hex integer literal, e.g.
/// `0xdead_beef_cafe_babe`. The underscores make the emitted source
/// human-readable in `-dump-macro-expansions` output; Swift's integer
/// literal parser ignores them.
private func hexLiteral(_ value: UInt64) -> String {
  let digits: [Character] = Array("0123456789abcdef")
  var hex = ""
  for i in stride(from: 60, through: 0, by: -4) {
    let nibble = Int((value >> UInt64(i)) & 0xf)
    hex.append(digits[nibble])
    if i > 0 && i % 16 == 0 { hex.append("_") }
  }
  return "0x\(hex)"
}
