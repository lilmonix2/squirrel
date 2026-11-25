//
//  SquirrelAutoSpacing.swift
//  Squirrel
//

struct SquirrelAutoSpacing {
  let english: Bool
  let digits: Bool

  var enabled: Bool { english || digits }

  enum CaretAction {
    case none
    case moveLeft
    case deleteRightSpace
  }

  struct Result {
    var text: String
    var caretAction: CaretAction = .none
  }

  private enum CharacterKind {
    case han, english, digit, other
  }

  private func kind(of character: Character) -> CharacterKind {
    if let ascii = character.asciiValue {
      switch ascii {
      case 65...90, 97...122:
        return .english
      case 48...57, 37:
        return .digit
      default:
        return .other
      }
    }
    switch character {
    case "‰", "°", "℉", "′", "″", "℃":
      return .digit
    default:
      return character.unicodeScalars.allSatisfy { (0x4E00...0x9FA5).contains($0.value) } ? .han : .other
    }
  }

  func handlesDigit(_ character: Character) -> Bool {
    digits && kind(of: character) == .digit
  }

  private func needsSpace(_ left: Character?, _ right: Character?) -> Bool {
    guard let left = left, let right = right else { return false }
    switch (kind(of: left), kind(of: right)) {
    case (.han, .english), (.english, .han):
      return english
    case (.han, .digit), (.digit, .han):
      return digits
    default:
      return false
    }
  }

  func format(_ text: String, before: String?, after: String?, cachedTail: Character?,
              previousKeyWasDelete: Bool = false, leadingOnly: Bool = false) -> Result {
    guard enabled, let first = text.first, let last = text.last else { return Result(text: text) }

    var result = Result(text: "")
    var previous: Character?
    for current in text {
      if needsSpace(previous, current) {
        result.text.append(" ")
      }
      result.text.append(current)
      previous = current
    }

    let hasContext = before != nil || after != nil
    if hasContext && (previousKeyWasDelete || (!leadingOnly && after != nil && before?.contains("#") == true)) {
      return result
    }

    let left = before == nil ? cachedTail : before?.last
    if needsSpace(left, first) {
      result.text = " " + result.text
    }
    guard !leadingOnly, let after = after else { return result }

    if needsSpace(last, after.first) {
      result.text.append(" ")
      result.caretAction = .moveLeft
    } else if after.first == " ", let next = after.dropFirst().first, !needsSpace(last, next) {
      result.caretAction = .deleteRightSpace
    }
    return result
  }
}
