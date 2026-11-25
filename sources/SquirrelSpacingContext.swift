//
//  SquirrelSpacingContext.swift
//  Squirrel
//

import ApplicationServices
import InputMethodKit

final class SquirrelSpacingContext {
  private struct CommitPosition {
    let start: Int?
    let replacement: NSRange?
    let canUseCachedTail: Bool
  }

  private struct CaretTarget {
    let pid: pid_t
    let element: AXUIElement
    let end: Int
  }

  private enum Fragment {
    case unavailable
    case incomplete
    case available(String)

    var text: String? {
      if case .available(let text) = self { return text }
      return nil
    }
  }

  private struct Neighbors {
    var before: Fragment = .unavailable
    var after: Fragment = .unavailable
  }

  private var lastCommit: (tail: Character, end: Int?)?
  private var insertedSuffix: (tail: Character, end: Int)?
  private var composition: (start: Int, neighbors: Neighbors)?
  private var mouseMonitor: Any?
  private var lastKeyWasDelete = false
  private var skipBoundaries = false
  private var caretGeneration = 0

  deinit {
    if let monitor = mouseMonitor {
      NSEvent.removeMonitor(monitor)
    }
  }

  func reset() {
    lastCommit = nil
    insertedSuffix = nil
    composition = nil
    lastKeyWasDelete = false
    skipBoundaries = false
    caretGeneration &+= 1
  }

  func deactivate() {
    reset()
    if let monitor = mouseMonitor {
      NSEvent.removeMonitor(monitor)
      mouseMonitor = nil
    }
  }

  func beginKeyDown(_ event: NSEvent) {
    guard event.type == .keyDown else { return }
    caretGeneration &+= 1
    skipBoundaries = lastKeyWasDelete
    if isDelete(event) {
      lastCommit = nil
      insertedSuffix = nil
    }
  }

  func endKeyDown(_ event: NSEvent, handled: Bool) {
    guard event.type == .keyDown else { return }
    if !handled {
      reset()
    }
    lastKeyWasDelete = isDelete(event)
  }

  func updatePreedit(_ preedit: String, wasEmpty: Bool, client: IMKTextInput, enabled: Bool) {
    if preedit.isEmpty {
      composition = nil
    } else if wasEmpty && enabled {
      insertedSuffix = nil
      // Capture committed neighbors before the host inserts marked text.
      let selection = client.selectedRange()
      if isValid(selection) {
        composition = (selection.location, readNeighbors(in: client, start: selection.location, end: selection.upperBound))
      }
    }
  }

  @discardableResult
  func insertCommit(_ text: String, spacing: SquirrelAutoSpacing, client: IMKTextInput, preeditLength: Int,
                    forwardingUnchanged: Bool = false, insert: (String, NSRange) -> Void) -> Bool {
    let position = commitPosition(in: client, preeditLength: preeditLength)
    var live = readNeighbors(in: client, start: position.start, end: position.replacement?.upperBound)
    var start = position.start
    var range = NSRange.empty
    var canReplace: Bool {
      position.replacement != nil && client.supportsProperty(TSMDocumentPropertyTag(kTSMDocumentSupportDocumentAccessPropertyTag))
    }
    // A following literal can replace our own trailing space if the caret stayed after it.
    if forwardingUnchanged, !skipBoundaries, let suffix = insertedSuffix, let selection = position.replacement,
       selection.location == suffix.end, selection.length == 0, let before = live.before.text,
       before.hasSuffix(String(suffix.tail) + " "), live.after.text != nil, canReplace {
      range = NSRange(location: selection.location - 1, length: 1)
      start = range.location
      live.before = .available(String(before.dropLast()))
    }
    insertedSuffix = nil

    var result = format(text, spacing: spacing, position: position, live: live)
    let caretTarget = result.caretAction == .moveLeft
      ? prepareCaretTarget(client: client, start: start, text: result.text) : nil
    let canContinueBeforeSuffix = result.caretAction == .moveLeft && canReplace
    if forwardingUnchanged, result.caretAction == .moveLeft, caretTarget == nil, !canContinueBeforeSuffix {
      // Preserve continuous literal input when the editor offers neither caret movement nor replacement.
      result.text.removeLast()
      result.caretAction = .none
    }
    // Delete only a space whose live context was verified.
    if !forwardingUnchanged, result.caretAction == .deleteRightSpace, let replacement = position.replacement,
       live.after.text?.first == " ", replacement.upperBound < NSNotFound - 1, canReplace {
      range = NSRange(location: replacement.location, length: replacement.length + 1)
    }
    if forwardingUnchanged, result.text == text, range == .empty {
      rememberCommit(text, at: start)
      return false
    }

    caretGeneration &+= 1
    insert(result.text, range)
    rememberCommit(result.text, at: start)
    if canContinueBeforeSuffix, let end = lastCommit?.end, let tail = result.text.dropLast().last {
      insertedSuffix = (tail, end)
    }
    composition = nil
    if let caretTarget = caretTarget {
      moveCaretBeforeSuffix(client: client, target: caretTarget, text: result.text)
    }
    return true
  }

  func plainCommit() {
    lastCommit = nil
    insertedSuffix = nil
    composition = nil
    caretGeneration &+= 1
  }

  func insertForwardedLiteral(_ character: Character, spacing: SquirrelAutoSpacing, client: IMKTextInput,
                              insert: (String, NSRange) -> Void) -> Bool? {
    let continuesNumber = spacing.digits && (character == "." || character == ",") &&
      insertedSuffix?.tail.asciiValue.map { (48...57).contains($0) } == true
    guard spacing.handlesLiteral(character) || continuesNumber else { return nil }
    return insertCommit(String(character), spacing: spacing, client: client, preeditLength: 0,
                        forwardingUnchanged: true, insert: insert)
  }
}

extension SquirrelSpacingContext {
  private func isDelete(_ event: NSEvent) -> Bool {
    event.keyCode == kVK_Delete || event.keyCode == kVK_ForwardDelete
  }

  private func isValid(_ range: NSRange) -> Bool {
    range.location >= 0 && range.location < NSNotFound && range.length >= 0 &&
      range.length < NSNotFound - range.location
  }

  private func commitPosition(in client: IMKTextInput, preeditLength: Int) -> CommitPosition {
    let marked = client.markedRange()
    let range = isValid(marked) && marked.length > 0 ? marked : (preeditLength == 0 ? client.selectedRange() : .empty)
    let hasRange = isValid(range)
    let start = composition?.start ?? (hasRange ? range.location : nil)
    // A stale marked length can put the reported end inside the preedit. The
    // original selection still gives us the right neighbor in that case.
    let hasValidEnd = hasRange && range.location == start && (preeditLength == 0 || range.length == preeditLength)
    let canUseCachedTail = composition != nil || !hasRange || range.length == preeditLength
    return CommitPosition(start: start, replacement: hasValidEnd ? range : nil, canUseCachedTail: canUseCachedTail)
  }

  private func format(_ text: String, spacing: SquirrelAutoSpacing, position: CommitPosition,
                      live: Neighbors) -> SquirrelAutoSpacing.Result {
    var before = live.before.text ?? composition?.neighbors.before.text
    if before == nil, case .incomplete = live.before {
      // A known fragment is different from an unavailable context. Do not
      // replace the fragment with an unrelated cached character.
      before = ""
    }
    if before == nil, let composition = composition, case .incomplete = composition.neighbors.before {
      before = ""
    }
    let cachedTail = position.canUseCachedTail && position.start != 0 && (position.start == nil || position.start == lastCommit?.end)
      ? lastCommit?.tail : nil
    let after = live.after.text ?? composition?.neighbors.after.text
    return spacing.format(text, before: before, after: after, cachedTail: cachedTail,
                          previousKeyWasDelete: skipBoundaries)
  }

  private func rememberCommit(_ text: String, at start: Int?) {
    guard let tail = text.last else {
      lastCommit = nil
      return
    }
    if mouseMonitor == nil {
      mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
        self?.reset()
      }
    }
    guard mouseMonitor != nil else { return }
    let count = text.utf16.count
    let end = start.flatMap { $0 < NSNotFound - count ? $0 + count : nil }
    lastCommit = (tail, end)
  }

  private func readNeighbors(in client: IMKTextInput, start: Int?, end: Int?) -> Neighbors {
    guard start != nil || end != nil else { return Neighbors() }
    let reportedLength = client.length()
    let lastBoundary = max(start ?? 0, end ?? 0)
    // Some clients report zero even with valid document-relative offsets.
    let documentEnd = reportedLength > 0 && reportedLength >= lastBoundary ? reportedLength : NSNotFound
    var neighbors = Neighbors()
    if let start = start {
      neighbors.before = start == 0 ? .available("") : readFragment(in: client, boundary: start, length: min(64, start),
                                                                    before: true, documentEnd: documentEnd)
    }
    if let end = end {
      neighbors.after = end == documentEnd ? .available("") : readFragment(in: client, boundary: end, length: min(8, documentEnd - end),
                                                                           before: false, documentEnd: documentEnd)
    }
    return neighbors
  }

  private func readFragment(in client: IMKTextInput, boundary: Int, length: Int, before: Bool, documentEnd: Int) -> Fragment {
    var previousSize = 0
    for size in [length, min(8, length), min(2, length), 1] where size != previousSize {
      previousSize = size
      let range = NSRange(location: before ? boundary - size : boundary, length: size)
      var actual = NSRange.empty
      if let text = client.string(from: range, actualRange: &actual), isValid(actual),
         actual.length > 0, text.utf16.count == actual.length,
         (before ? actual.upperBound == boundary : actual.location == boundary) {
        return completeCharacters(in: text, range: actual, before: before, documentEnd: documentEnd)
      }

      // Without an actual range, accept only an exact-size result from a client
      // that supports document-relative requests.
      if client.supportsProperty(TSMDocumentPropertyTag(kTSMDocumentSupportDocumentAccessPropertyTag)),
         let text = client.attributedSubstring(from: range), text.length == size {
        return completeCharacters(in: text.string, range: range, before: before, documentEnd: documentEnd)
      }
    }
    return .unavailable
  }

  private func completeCharacters(in text: String, range: NSRange, before: Bool, documentEnd: Int) -> Fragment {
    let reachesDocumentEdge = before ? range.location == 0 : range.upperBound == documentEnd
    if reachesDocumentEdge {
      return .available(text)
    }
    // The outer edge of a UTF-16 slice may be inside a grapheme cluster.
    // Keep only characters whose outer boundary is present in the fragment.
    let complete = before ? text.dropFirst() : text.dropLast()
    if complete.isEmpty, text.utf16.count == 1, let scalar = text.unicodeScalars.first,
       (0x4E00...0x9FA5).contains(scalar.value) {
      // Some clients return the neighboring Han character without reporting the document end.
      return .available(text)
    }
    return complete.isEmpty ? .incomplete : .available(String(complete))
  }

  private func prepareCaretTarget(client: IMKTextInput, start: Int?, text: String) -> CaretTarget? {
    let length = text.utf16.count
    guard let start = start, length > 0, start < NSNotFound - length, AXIsProcessTrusted(),
          let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == client.bundleIdentifier(),
          let element = focusedTextElement(in: app.processIdentifier) else { return nil }
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
          settable.boolValue else { return nil }
    return CaretTarget(pid: app.processIdentifier, element: element, end: start + length)
  }

  private func focusedTextElement(in pid: pid_t) -> AXUIElement? {
    var focused: CFTypeRef?
    let application = AXUIElementCreateApplication(pid)
    guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let focused = focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
    return (focused as! AXUIElement)
  }

  private func moveCaretBeforeSuffix(client: IMKTextInput, target: CaretTarget, text: String) {
    let generation = caretGeneration
    DispatchQueue.main.async { [weak self, weak client] in
      guard let self = self, client != nil, generation == self.caretGeneration,
            NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
            let element = self.focusedTextElement(in: target.pid), CFEqual(element, target.element) else { return }
      let attribute = kAXSelectedTextRangeAttribute as CFString
      var value: CFTypeRef?
      var selection = CFRange()
      guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
            let value = value, CFGetTypeID(value) == AXValueGetTypeID(),
            AXValueGetValue(value as! AXValue, .cfRange, &selection),
            selection.location == target.end, selection.length == 0 else { return }
      var newSelection = CFRange(location: target.end - 1, length: 0)
      if let range = AXValueCreate(.cfRange, &newSelection),
         AXUIElementSetAttributeValue(element, attribute, range) == .success,
         let tail = text.dropLast().last {
        self.lastCommit = (tail, newSelection.location)
      }
    }
  }
}
