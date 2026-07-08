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

import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics
import SwiftSyntaxBuilder

// ==== -----------------------------------------------------------------------
// MARK: @Entitlement

// FIXME: This is not intended to ship in stdlib; this is just a PoC how such macro would look like.
public struct EntitlementMacro: _DistributedValidationMacroImpl {
  static var attributeName: String { "@Entitlement" }
}

extension EntitlementMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    let target = try diagnoseAttachmentSite(
      attributeName: attributeName,
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
    let enclosing = try enclosingTypeName(context,
        attributeName: attributeName, node: node, declaration: declaration)

    let policyExpression = entitlementPolicyExpression(from: node)
    // `@Entitlement` maps onto a `RemoteCallValidator` whose closure
    // evaluates the entitlement policy against the receive-side task-local
    // entitlement set. The context argument is ignored: entitlement policies
    // read from `DistributedValidation.currentEntitlements` (a task-local),
    // not from the caller-provided context.
    let validatorExpression =
      """
      Distributed.RemoteCallValidator<\(enclosing).ActorSystem>({ _ in
        try Distributed.DistributedValidation.evaluate(\(policyExpression))
      })
      """
    return emitValidationPeers(
      targetName: targetName,
      enclosingTypeName: enclosing,
      validatorExpression: validatorExpression,
      in: context)
  }
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
    fatalError("Not well formed @Entitlement()") // TODO: entitlement macro is not production ready in here, it's just a PoC, normally we'd emit a nce error here
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
