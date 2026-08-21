import Foundation

struct PromptValidationResult: Equatable {
    var errors: [String]

    var isValid: Bool { errors.isEmpty }
}

enum PromptEngineError: LocalizedError {
    case invalidTemplate([String])

    var errorDescription: String? {
        switch self {
        case .invalidTemplate(let errors):
            return errors.joined(separator: "\n")
        }
    }
}

enum PromptEngine {
    static let requiredVariables = ["target_language", "addition", "input"]

    static func validate(_ template: String) -> PromptValidationResult {
        var errors: [String] = []
        let pattern = #"\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(template.startIndex..<template.endIndex, in: template)
        let matches = regex?.matches(in: template, range: range) ?? []
        let variables = matches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: template) else { return nil }
            return String(template[range])
        }

        for variable in requiredVariables {
            let count = variables.filter { $0 == variable }.count
            if count == 0 {
                errors.append("缺少系统变量 {{\(variable)}}。")
            } else if count > 1 {
                errors.append("系统变量 {{\(variable)}} 只能出现一次。")
            }
        }

        let unknown = Set(variables).subtracting(requiredVariables).sorted()
        for variable in unknown {
            errors.append("不支持系统变量 {{\(variable)}}。")
        }

        let openingTagCount = template.components(separatedBy: "<translate>").count - 1
        let closingTagCount = template.components(separatedBy: "</translate>").count - 1
        if openingTagCount != 2 || closingTagCount != 2 {
            errors.append("<translate> 与 </translate> 标签必须各出现两次。")
        } else {
            let tagPattern = #"</?translate>"#
            let tagRegex = try? NSRegularExpression(pattern: tagPattern)
            let tagMatches = tagRegex?.matches(in: template, range: range) ?? []
            let tags = tagMatches.compactMap { match -> String? in
                guard let tagRange = Range(match.range, in: template) else { return nil }
                return String(template[tagRange])
            }
            if tags != ["<translate>", "</translate>", "<translate>", "</translate>"] {
                errors.append("翻译标签必须按两组成对的顺序出现。")
            }
        }

        return PromptValidationResult(errors: errors)
    }

    static func render(
        template: String,
        targetLanguage: String,
        addition: String,
        input: String
    ) throws -> String {
        let validation = validate(template)
        guard validation.isValid else {
            throw PromptEngineError.invalidTemplate(validation.errors)
        }

        return template
            .replacingOccurrences(of: "{{target_language}}", with: targetLanguage)
            .replacingOccurrences(of: "{{addition}}", with: addition)
            .replacingOccurrences(of: "{{input}}", with: input)
    }
}
