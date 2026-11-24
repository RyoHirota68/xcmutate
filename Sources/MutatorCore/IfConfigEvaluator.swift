import SwiftSyntax

/// Decides, where it can be decided from the destination alone, whether a branch of `#if` is compiled.
///
/// Only platform conditions are evaluated: `os(…)`, `targetEnvironment(simulator)` / `(macCatalyst)`,
/// `canImport(UIKit)` / `(AppKit)`, combined with `!`, `&&`, `||` and parentheses. Anything else (`DEBUG` and other
/// compilation conditions, `arch`, `swift` and `compiler` versions, other modules) is unknown, and a branch whose
/// state is unknown is treated as compiled: its mutants are made, as before.
enum IfConfigEvaluator {
    /// true / false if it is known whether `clause` is compiled for `platform`, nil if it is not known.
    static func isCompiled(_ clause: IfConfigClauseSyntax, for platform: TargetPlatform) -> Bool? {
        guard let clauses = clause.parent?.as(IfConfigClauseListSyntax.self) else { return nil }
        // The first clause whose condition holds is the one compiled; `#else` has no condition
        for candidate in clauses {
            let holds: Bool? = candidate.condition.map { evaluate($0, for: platform) } ?? true
            if candidate.id == clause.id {
                // Every clause before this one is known not to hold
                return holds
            }
            guard holds == false else {
                // An earlier clause holds (this one is not compiled), or it is not known whether it does
                return holds == true ? false : nil
            }
        }
        return nil
    }

    static func evaluate(_ expression: ExprSyntax, for platform: TargetPlatform) -> Bool? {
        if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1, let inner = tuple.elements.first, inner.label == nil {
            return evaluate(inner.expression, for: platform)
        }
        if let prefix = expression.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "!" {
            return evaluate(prefix.expression, for: platform).map { !$0 }
        }
        if let infix = expression.as(InfixOperatorExprSyntax.self), let op = infix.operator.as(BinaryOperatorExprSyntax.self)?.operator.text {
            let left = evaluate(infix.leftOperand, for: platform)
            let right = evaluate(infix.rightOperand, for: platform)
            switch op {
            case "&&":
                if left == false || right == false { return false }
                return left == true && right == true ? true : nil
            case "||":
                if left == true || right == true { return true }
                return left == false && right == false ? false : nil
            default:
                return nil
            }
        }
        guard let call = expression.as(FunctionCallExprSyntax.self), let name = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
              call.arguments.count == 1, let argument = call.arguments.first, argument.label == nil,
              let value = argument.expression.as(DeclReferenceExprSyntax.self)?.baseName.text else { return nil }
        switch name {
        case "os":
            // Mac Catalyst code is compiled as iOS
            guard ["iOS", "macOS", "tvOS", "watchOS", "visionOS", "Linux", "Windows", "Android", "FreeBSD", "WASI"].contains(value) else { return nil }
            return value == platform.os
        case "targetEnvironment":
            switch value {
            case "simulator": return platform.isSimulator
            case "macCatalyst": return platform.isMacCatalyst
            default: return nil
            }
        case "canImport":
            switch value {
            case "UIKit": return platform.os != "macOS"
            case "AppKit": return platform.os == "macOS" || platform.isMacCatalyst
            default: return nil
            }
        default:
            return nil
        }
    }
}
