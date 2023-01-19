// The MIT License (MIT)
//
// Copyright (c) 2020–2023 Alexander Grebenyuk (github.com/kean).

import SwiftUI
import Pulse
import CoreData
import Combine

@available(iOS 15, tvOS 15, *)
final class ConsoleSearchService {
    private let helper = TextHelper()
    private let cachedBodies = Cache<NSManagedObjectID, NSString>(costLimit: 16_000_000, countLimit: 1000)

    func search(in message: LoggerMessageEntity, parameters: ConsoleSearchParameters) -> [ConsoleSearchOccurrence] {
        search(message.text as NSString, parameters, .message)
    }

    func isMatching(_ task: NetworkTaskEntity, filters: [ConsoleSearchFilter]) -> Bool {
        filters.allSatisfy { $0.filter.isMatch(task) }
    }

    func search(in task: NetworkTaskEntity, parameters: ConsoleSearchParameters) -> [ConsoleSearchOccurrence] {
        var occurrences: [ConsoleSearchOccurrence] = []
        for scope in parameters.scopes {
            switch scope {
            case .url:
                if var components = URLComponents(string: task.url ?? "") {
                    components.queryItems = nil
                    if let url = components.url?.absoluteString {
                        occurrences += search(url as NSString, parameters, scope)
                    }
                }
            case .queryItems:
                if let components = URLComponents(string: task.url ?? ""),
                   let query = components.query, !query.isEmpty {
                    occurrences += search(query as NSString, parameters, scope)
                }
            case .originalRequestHeaders:
                if let headers = task.originalRequest?.httpHeaders {
                    occurrences += search(headers as NSString, parameters, scope)
                }
            case .currentRequestHeaders:
                if let headers = task.currentRequest?.httpHeaders {
                    occurrences += search(headers as NSString, parameters, scope)
                }
            case .requestBody:
                if let string = task.requestBody.flatMap(getBodyString) {
                    occurrences += search(string, parameters, scope)
                }
            case .responseHeaders:
                if let headers = task.response?.httpHeaders {
                    occurrences += search(headers as NSString, parameters, scope)
                }
            case .responseBody:
                if let string = task.responseBody.flatMap(getBodyString) {
                    occurrences += search(string, parameters, scope)
                }
            case .message:
                break // Applies only to LoggerMessageEntity
            }
        }
        return occurrences
    }

    private func search(_ data: Data, _ parameters: ConsoleSearchParameters, _ scope: ConsoleSearchScope) -> [ConsoleSearchOccurrence] {
        guard let content = NSString(data: data, encoding: NSUTF8StringEncoding) else {
            return []
        }
        return search(content, parameters, scope)
    }

    private func search(_ content: NSString, _ parameters: ConsoleSearchParameters, _ scope: ConsoleSearchScope) -> [ConsoleSearchOccurrence] {
        var matchedTerms: Set<ConsoleSearchTerm> = []
        var allMatches: [(line: NSString, lineNumber: Int, range: NSRange, term: ConsoleSearchTerm)] = []
        var lineCount = 0
        content.enumerateLines { line, stop in
            lineCount += 1
            let line = line as NSString
            for term in parameters.terms {
                let matches = line.ranges(of: term.text, options: .init(term.options))
                for range in matches {
                    allMatches.append((line, lineCount, range, term))
                }
                if !matches.isEmpty {
                    matchedTerms.insert(term)
                }
            }
        }

        guard matchedTerms.count == Set(parameters.terms).count else {
            return [] // Has to match all
        }

        var occurrences: [ConsoleSearchOccurrence] = []
        var matchIndex = 0
        for (line, lineNumber, range, term) in allMatches {
            let lineRange = lineCount == 1 ? NSRange(location: 0, length: content.length) :  (line.getLineRange(range) ?? range) // Optimization for long lines

            var prefixRange = NSRange(location: lineRange.location, length: range.location - lineRange.location)
            var suffixRange = NSRange(location: range.upperBound, length: lineRange.upperBound - range.upperBound)


            // Reduce context to a reasonable size
            var needsPrefixEllipsis = false
            if prefixRange.length > 30 {
                let distance = prefixRange.length - 30
                prefixRange.length = 30
                prefixRange.location += distance
                needsPrefixEllipsis = true
            }
            suffixRange.length = min(120, suffixRange.length)

            // Trim whitespace and some punctuation characters from the end of the string
            while prefixRange.location < range.location, shouldTrimCharacter(line.character(at: prefixRange.location)) {
                prefixRange.location += 1
                prefixRange.length -= 1
            }
            while (suffixRange.upperBound - 1) > range.location, shouldTrimCharacter(line.character(at: (suffixRange.upperBound - 1))) {
                suffixRange.length -= 1
            }

            // Try to trim the prefix at the start of the word
            while prefixRange.location > 0,
                  let character = Character(line.character(at: prefixRange.location)),
                  !character.isWhitespace,
                  prefixRange.length < 50 {
                prefixRange.location -= 1
                prefixRange.length += 1
            }

            let attributes = AttributeContainer(helper.attributes(role: .body2, style: .monospaced))
            let prefix = AttributedString((needsPrefixEllipsis ? "…" : "") + line.substring(with: prefixRange), attributes: attributes)
            var match = AttributedString(line.substring(with: range), attributes: attributes)
            match.foregroundColor = .orange
            let suffix = AttributedString(line.substring(with: suffixRange), attributes: attributes)
            let preview = prefix + match + suffix

            let occurrence = ConsoleSearchOccurrence(
                scope: scope,
                line: lineNumber,
                range: range,
                text: preview,
                searchContext: .init(searchTerm: term, matchIndex: matchIndex)
            )
            occurrences.append(occurrence)

            matchIndex += 1
        }

        return occurrences
    }

    private func getBodyString(for blob: LoggerBlobHandleEntity) -> NSString? {
        if let string = cachedBodies.value(forKey: blob.objectID)  {
            return string
        }
        guard let data = blob.data,
              let string = NSString(data: data, encoding: NSUTF8StringEncoding)
        else {
            return nil
        }
        cachedBodies.set(string, forKey: blob.objectID, cost: data.count)
        return string
    }
}

@available(iOS 15, tvOS 15, *)
struct ConsoleSearchOccurrence {
    let scope: ConsoleSearchScope
    let line: Int
    let range: NSRange
    let text: AttributedString
    let searchContext: RichTextViewModel.SearchContext
}

private func shouldTrimCharacter(_ character: unichar) -> Bool {
    guard let character = Character(character) else { return true }
    return character.isNewline || character.isWhitespace || character == ","
}