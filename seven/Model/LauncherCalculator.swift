import Foundation
import SoulverCore

struct LauncherCalculation: Identifiable, Codable, Equatable {
    var id = UUID()
    let expression: String
    let result: String
    let numericValue: Double?
}

/// Owns the calculator session. Previews never mutate saved variables.
final class LauncherCalculator {
    struct Evaluation {
        let expression: String
        let result: String
        let numericValue: Double?
        fileprivate let variableName: String?
        fileprivate let value: EvaluationResult
    }

    private let engine: Calculator
    private var variables: [String: EvaluationResult] = [:]

    init() {
        engine = Calculator(customization: .standard)
        var formatting = FormattingPreferences()
        formatting.dp = 12
        engine.formattingPreferences = formatting
    }

    func assignmentPreview(for expression: String) -> Evaluation? {
        guard expression.contains("="), let evaluation = evaluate(expression, allowingAssignment: true),
              evaluation.variableName != nil else { return nil }
        return evaluation
    }

    func referencesSavedVariable(in expression: String) -> Bool {
        let input = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        return variables.keys.contains { name in
            guard input.hasPrefix(name) else { return false }
            let suffix = input.dropFirst(name.count)
            return suffix.isEmpty || suffix.first!.isWhitespace || "+-*/×÷^=%".contains(suffix.first!)
        }
    }

    func evaluate(_ expression: String, allowingAssignment: Bool = false) -> Evaluation? {
        let input = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.count <= 512,
              !"=+-*/×÷^".contains(input.last!), balancedParentheses(in: input) else { return nil }
        if input.contains("=") {
            let parts = input.components(separatedBy: "=")
            guard allowingAssignment, parts.count == 2 else { return nil }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard name.range(of: #"^[\p{L}_][\p{L}\p{N}_]*(?: +[\p{L}_][\p{L}\p{N}_]*)*$"#,
                             options: .regularExpression) != nil,
                  let rhs = evaluate(parts[1]) else { return nil }
            return Evaluation(expression: input, result: rhs.result, numericValue: rhs.numericValue,
                              variableName: name, value: rhs.value)
        }
        // Supply typed values, so a saved third retains its precision and a
        // saved distance retains its unit regardless of how it was formatted.
        let list = VariableList(variables: variables.map { name, definition in
            var variable = Variable(name: name, value: nil)
            variable.definition = definition
            return variable
        })
        let calculation = engine.calculate(input, with: list)
        let value = calculation.evaluationResult
        guard value.errorValue == nil, !calculation.isEmptyResult,
              !calculation.isPendingResult, !calculation.isFailedResult,
              !calculation.stringValue.isEmpty else { return nil }
        switch value {
        case .none, .pending, .failed, .error: return nil
        default: break
        }
        if let decimal = value.decimalValue, decimal.isNaN { return nil }
        let number = value.decimalValue.map { NSDecimalNumber(decimal: $0).doubleValue }
        guard number?.isFinite != false else { return nil }
        return Evaluation(expression: input, result: calculation.stringValue,
                          numericValue: number, variableName: nil, value: value)
    }

    func commit(_ evaluation: Evaluation) {
        if let name = evaluation.variableName {
            variables[name] = evaluation.value
        }
    }

    private func balancedParentheses(in input: String) -> Bool {
        var depth = 0
        for character in input {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if depth < 0 { return false }
        }
        return depth == 0
    }
}
