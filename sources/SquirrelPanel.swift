//
//  SquirrelPanel.swift
//  Squirrel
//
//  Created by Leo Liu on 5/10/24.
//

import AppKit

final class SquirrelPanel: NSPanel {
  private let view: SquirrelView
  private let back: NSView
  var inputController: SquirrelInputController?

  var position: NSRect
  private var screenRect: NSRect = .zero
  private var maxHeight: CGFloat = 0

  private var statusMessage: String = ""
  private var statusTimer: Timer?

  private var preedit: String = ""
  private var selRange: NSRange = .empty
  private var caretPos: Int = 0
  private var candidates: [String] = .init()
  private var comments: [String] = .init()
  private var labels: [String] = .init()
  private var index: Int = 0
  private var cursorIndex: Int = 0
  private var scrollDirection: CGVector = .zero
  private var scrollTime: Date = .distantPast
  private var page: Int = 0
  private var lastPage: Bool = true
  private var pagingUp: Bool?
  private var pressedCandidate: Int?
  private var scrollColumns = 0
  private var wasScrollMode = false
  private var scrollAnimationGeneration = 0
  private var hasChineseCandidates = false

  init(position: NSRect) {
    self.position = position
    self.view = SquirrelView(frame: position)
    self.back = Self.makeBackgroundView()
    super.init(contentRect: position, styleMask: .nonactivatingPanel, backing: .buffered, defer: true)
    self.level = .init(Int(CGShieldingWindowLevel()))
    self.hasShadow = true
    self.isOpaque = false
    self.backgroundColor = .clear
    back.wantsLayer = true
    back.layer?.mask = view.shape
    back.autoresizingMask = [.width, .height]
    view.autoresizingMask = [.width, .height]
    let contentView = NSView()
    contentView.addSubview(back)
    contentView.addSubview(view)
    contentView.addSubview(view.textView)
    self.contentView = contentView
  }

  var linear: Bool {
    view.currentTheme.linear
  }
  var vertical: Bool {
    view.currentTheme.vertical
  }
  var inlinePreedit: Bool {
    view.currentTheme.inlinePreedit
  }
  var inlineCandidate: Bool {
    view.currentTheme.inlineCandidate
  }
  var canExpandCandidates: Bool {
    isVisible && scrollColumns == 0 && showsExpandControl
  }
  private var showsExpandControl: Bool {
    hasChineseCandidates && linear && !vertical && !lastPage
  }

  // swiftlint:disable:next cyclomatic_complexity
  override func sendEvent(_ event: NSEvent) {
    switch event.type {
    case .leftMouseDown:
      let (index, _, pagingUp) =  view.click(at: mousePosition())
      if let pagingUp {
        self.pagingUp = pagingUp
      } else {
        self.pagingUp = nil
      }
      pressedCandidate = index
    case .leftMouseUp:
      let pressedCandidate = self.pressedCandidate
      self.pressedCandidate = nil
      let (index, preeditIndex, pagingUp) = view.click(at: mousePosition())

      if let pagingUp, pagingUp == self.pagingUp {
        if pagingUp {
          if scrollColumns > 0 && page == 0 {
            _ = inputController?.collapseCandidateList()
          } else {
            _ = inputController?.page(up: true)
          }
        } else if !canExpandCandidates || inputController?.expandCandidateList() != true {
          _ = inputController?.page(up: false)
        }
      } else {
        self.pagingUp = nil
      }
      if let preeditIndex, preeditIndex >= 0 && preeditIndex < preedit.utf16.count {
        if preeditIndex < caretPos {
          _ = inputController?.moveCaret(forward: true)
        } else if preeditIndex > caretPos {
          _ = inputController?.moveCaret(forward: false)
        }
      }
      if let index, index == pressedCandidate && index >= 0 && index < candidates.count {
        _ = inputController?.selectCandidate(index)
      }
    case .mouseEntered:
      acceptsMouseMovedEvents = true
    case .mouseExited:
      acceptsMouseMovedEvents = false
      if cursorIndex != index {
        update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels, highlighted: index, page: page, lastPage: lastPage, update: false)
      }
      pagingUp = nil
    case .mouseMoved:
      let (index, _, _) = view.click(at: mousePosition())
      if let index = index, cursorIndex != index && index >= 0 && index < candidates.count {
        update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels, highlighted: index, page: page, lastPage: lastPage, update: false)
      }
    case .scrollWheel:
      if event.phase == .began {
        scrollDirection = .zero
      } else if event.phase == .ended || (event.phase == .init(rawValue: 0) && event.momentumPhase != .init(rawValue: 0)) {
        if abs(scrollDirection.dx) > abs(scrollDirection.dy) && abs(scrollDirection.dx) > 10 {
          _ = inputController?.page(up: (scrollDirection.dx < 0) == vertical)
        } else if abs(scrollDirection.dx) < abs(scrollDirection.dy) && abs(scrollDirection.dy) > 10 {
          _ = inputController?.page(up: scrollDirection.dy > 0)
        }
        scrollDirection = .zero
      } else if event.phase == .init(rawValue: 0) && event.momentumPhase == .init(rawValue: 0) {
        if scrollTime.timeIntervalSinceNow < -1 {
          scrollDirection = .zero
        }
        scrollTime = .now
        if (scrollDirection.dy >= 0 && event.scrollingDeltaY > 0) || (scrollDirection.dy <= 0 && event.scrollingDeltaY < 0) {
          scrollDirection.dy += event.scrollingDeltaY
        } else {
          scrollDirection = .zero
        }
        if abs(scrollDirection.dy) > 10 {
          _ = inputController?.page(up: scrollDirection.dy > 0)
          scrollDirection = .zero
        }
      } else {
        scrollDirection.dx += event.scrollingDeltaX
        scrollDirection.dy += event.scrollingDeltaY
      }
    default:
      break
    }
    super.sendEvent(event)
  }

  func hide() {
    statusTimer?.invalidate()
    statusTimer = nil
    scrollAnimationGeneration &+= 1
    view.textView.autoresizingMask = []
    orderOut(nil)
    pressedCandidate = nil
    scrollColumns = 0
    wasScrollMode = false
    hasChineseCandidates = false
    maxHeight = 0
  }

  // swiftlint:disable:next cyclomatic_complexity function_parameter_count
  func update(preedit: String, selRange: NSRange, caretPos: Int, candidates: [String], comments: [String], labels: [String], highlighted index: Int,
              page: Int, lastPage: Bool, update: Bool, scrollColumns: Int = 0, hasChineseCandidates: Bool = false) {
    if update {
      self.preedit = preedit
      self.selRange = selRange
      self.caretPos = caretPos
      self.candidates = candidates
      self.comments = comments
      self.labels = labels
      self.index = index
      self.page = page
      self.lastPage = lastPage
      self.scrollColumns = scrollColumns
      self.hasChineseCandidates = hasChineseCandidates
    }
    cursorIndex = index

    if !candidates.isEmpty || !preedit.isEmpty {
      statusMessage = ""
      statusTimer?.invalidate()
      statusTimer = nil
    } else {
      if !statusMessage.isEmpty {
        show(status: statusMessage)
        statusMessage = ""
      } else if statusTimer == nil {
        hide()
      }
      return
    }

    let theme = view.currentTheme
    let scrollColumns = self.scrollColumns
    currentScreen()

    let text = NSMutableAttributedString()
    let preeditRange: NSRange
    let highlightedPreeditRange: NSRange

    if !preedit.isEmpty {
      preeditRange = NSRange(location: 0, length: preedit.utf16.count)
      highlightedPreeditRange = selRange

      let line = NSMutableAttributedString(string: preedit)
      line.addAttributes(theme.preeditAttrs, range: preeditRange)
      line.addAttributes(theme.preeditHighlightedAttrs, range: selRange)
      text.append(line)

      text.addAttribute(.paragraphStyle, value: theme.preeditParagraphStyle, range: NSRange(location: 0, length: text.length))
      if !candidates.isEmpty {
        text.append(NSAttributedString(string: "\n", attributes: theme.preeditAttrs))
      }
    } else {
      preeditRange = .empty
      highlightedPreeditRange = .empty
    }

    // candidates
    let lineSeparator = linear ? "  " : "\n"
    let separatorMeasure = NSMutableAttributedString(string: lineSeparator, attributes: theme.attrs)
    if vertical {
      separatorMeasure.addAttribute(.verticalGlyphForm, value: 1, range: NSRange(location: 0, length: separatorMeasure.length))
    }
    view.separatorWidth = separatorMeasure.boundingRect(with: .zero).width

    let highlightedRow = scrollColumns > 0 && self.index >= 0 ? self.index / scrollColumns : -1
    var candidateLines = [NSMutableAttributedString]()
    candidateLines.reserveCapacity(candidates.count)
    for i in 0..<candidates.count {
      candidateLines.append(buildCandidateLine(candidateIndex: i, highlightedIndex: index, theme: theme, scrollColumns: scrollColumns, highlightedRow: highlightedRow))
    }

    let tabStops = scrollColumns > 0 ? scrollTabStops(for: candidateLines, scrollColumns: scrollColumns, theme: theme) : []
    var candidateRanges = [NSRange]()
    for i in 0..<candidateLines.count {
      let line = candidateLines[i]
      let row = scrollColumns > 0 ? i / scrollColumns : 0
      let column = scrollColumns > 0 ? i % scrollColumns : i
      let attrs = i == index ? theme.highlightedAttrs : theme.attrs

      let baseStyle = (scrollColumns > 0 ? row == 0 : i == 0) ? theme.firstParagraphStyle : theme.paragraphStyle
      let paragraphStyleCandidate = baseStyle.mutableCopy() as! NSMutableParagraphStyle
      if linear {
        if scrollColumns == 0 || row == 0 {
          paragraphStyleCandidate.paragraphSpacingBefore -= theme.linespace
        }
        paragraphStyleCandidate.lineSpacing = theme.linespace
      }
      if scrollColumns > 0 {
        paragraphStyleCandidate.tabStops = tabStops
        paragraphStyleCandidate.defaultTabInterval = 0
      } else if line.length > 0, let existingStyle = line.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
        paragraphStyleCandidate.headIndent = existingStyle.headIndent
      }
      line.addAttribute(.paragraphStyle, value: paragraphStyleCandidate, range: NSRange(location: 0, length: line.length))

      if i > 0 {
        let startsRow = scrollColumns > 0 && column == 0
        let separatorText = if scrollColumns > 0 {
          startsRow ? "\n" : "\t"
        } else {
          lineSeparator
        }
        let separator = NSMutableAttributedString(string: separatorText, attributes: attrs)
        if scrollColumns > 0 {
          separator.addAttribute(.paragraphStyle, value: paragraphStyleCandidate, range: NSRange(location: 0, length: separator.length))
        }
        text.append(separator)
      }

      candidateRanges.append(NSRange(location: text.length, length: line.length))
      text.append(line)
    }

    // text done!
    view.textView.textContentStorage?.attributedString = text
    view.textView.setLayoutOrientation(vertical ? .vertical : .horizontal)
    // Force TextKit 2 layout before measuring wrapped text and highlight bounds.
    let textWidth = maxTextWidth()
    let maxTextHeight = vertical ? screenRect.width - theme.edgeInset.width * 2 : screenRect.height - theme.edgeInset.height * 2
    view.textContainer.size = NSSize(width: textWidth, height: maxTextHeight)
    view.textLayoutManager.ensureLayout(for: view.textLayoutManager.documentRange)

    // Keep very tall wrapped text from auto-scrolling past the first line.
    view.textView.scrollToBeginningOfDocument(nil)

    view.drawView(candidateRanges: candidateRanges, hilightedIndex: index, preeditRange: preeditRange, highlightedPreeditRange: highlightedPreeditRange,
                  canPageUp: page > 0 || scrollColumns > 0, canPageDown: !lastPage,
                  showsScrollControls: scrollColumns > 0 || showsExpandControl)
    show()
  }

  func updateStatus(long longMessage: String, short shortMessage: String) {
    let theme = view.currentTheme
    switch theme.statusMessageType {
    case .mix:
      statusMessage = shortMessage.isEmpty ? longMessage : shortMessage
    case .long:
      statusMessage = longMessage
    case .short:
      if !shortMessage.isEmpty {
        statusMessage = shortMessage
      } else if let initial = longMessage.first {
        statusMessage = String(initial)
      } else {
        statusMessage = ""
      }
    }
  }

  func load(config: SquirrelConfig, forDarkMode isDark: Bool) {
    if isDark {
      view.darkTheme = SquirrelTheme()
      view.darkTheme.load(config: config, dark: true)
    } else {
      view.lightTheme = SquirrelTheme()
      view.lightTheme.load(config: config, dark: isDark)
    }
  }
}

private extension SquirrelPanel {
  func mousePosition() -> NSPoint {
    var point = NSEvent.mouseLocation
    point = self.convertPoint(fromScreen: point)
    return view.convert(point, from: nil)
  }

  func currentScreen() {
    if let screen = NSScreen.main {
      screenRect = screen.frame
    }
    for screen in NSScreen.screens where screen.frame.contains(position.origin) {
      screenRect = screen.frame
      break
    }
  }

  func maxTextWidth() -> CGFloat {
    let theme = view.currentTheme
    let font: NSFont = theme.font
    let fontScale = font.pointSize / 12
    let textWidthRatio = scrollColumns > 0 ? 0.90 : min(1, 1 / (vertical ? 4 : 3) + fontScale / 12)
    let maxWidth = if vertical {
      screenRect.height * textWidthRatio - theme.edgeInset.height * 2
    } else {
      screenRect.width * textWidthRatio - theme.edgeInset.width * 2 - (scrollColumns > 0 ? theme.pagingOffset : 0)
    }
    return maxWidth
  }

  // swiftlint:disable:next cyclomatic_complexity
  func show() {
    currentScreen()
    let theme = view.currentTheme
    if theme.native || view.darkTheme.available {
      self.appearance = NSApp.effectiveAppearance
    } else {
      // user configured only a light theme, set window appearance to light.
      self.appearance = NSAppearance(named: .aqua)
    }

    view.textView.textContainerInset = theme.edgeInset

    var textWidth = maxTextWidth()
    // Measure natural text height before constraining the panel.
    view.textContainer.size = NSSize(width: textWidth, height: .greatestFiniteMagnitude)

    // Do not let NSTextView shrink the container to the current view width; it can loop or hide text.
    view.textContainer.widthTracksTextView = false
    view.textContainer.heightTracksTextView = false

    view.textLayoutManager.ensureLayout(for: view.textLayoutManager.documentRange)
    view.textView.bounds.origin = .zero

    var contentRect = view.contentRect

    // Compute the largest size possible for a giant panel
    var naturalPanelSize = NSSize.zero
    if vertical {
      naturalPanelSize.width = contentRect.height + theme.edgeInset.height * 2
      naturalPanelSize.height = contentRect.width + theme.edgeInset.width * 2 + view.pagingOffset
    } else {
      naturalPanelSize.width = contentRect.width + theme.edgeInset.width * 2 + view.pagingOffset
      naturalPanelSize.height = contentRect.height + theme.edgeInset.height * 2
    }

    let maxAllowedWidth = screenRect.width * 0.95
    let maxAllowedHeight = screenRect.height * 0.95

    let requiresFullScreen = naturalPanelSize.width > maxAllowedWidth || naturalPanelSize.height > maxAllowedHeight

    if requiresFullScreen {
      // Expand line length before fullscreen scaling to avoid wasting screen space on narrow text.
      let area = contentRect.width * contentRect.height
      let screenRatio = maxAllowedWidth / maxAllowedHeight

      let optimalTextWidth: CGFloat
      if vertical {
        // Width = screen height in vertical mode
        optimalTextWidth = sqrt(area / screenRatio)
      } else {
        optimalTextWidth = sqrt(area * screenRatio)
      }

      // If there's extra room for text, tighten the layout
      if optimalTextWidth > textWidth {
        textWidth = optimalTextWidth
        view.textContainer.size = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        view.textLayoutManager.ensureLayout(for: view.textLayoutManager.documentRange)

        contentRect = view.contentRect

        if vertical {
          naturalPanelSize.width = contentRect.height + theme.edgeInset.height * 2
          naturalPanelSize.height = contentRect.width + theme.edgeInset.width * 2 + view.pagingOffset
        } else {
          naturalPanelSize.width = contentRect.width + theme.edgeInset.width * 2 + view.pagingOffset
          naturalPanelSize.height = contentRect.height + theme.edgeInset.height * 2
        }
      }
    }

    var panelRect = NSRect.zero

    if requiresFullScreen {
      let scaleX = maxAllowedWidth / naturalPanelSize.width
      let scaleY = maxAllowedHeight / naturalPanelSize.height
      let scale = min(scaleX, scaleY)

      panelRect.size = NSSize(width: naturalPanelSize.width * scale, height: naturalPanelSize.height * scale)

      panelRect.origin = NSPoint(
        x: screenRect.minX + (screenRect.width - panelRect.width) / 2,
        y: screenRect.minY + (screenRect.height - panelRect.height) / 2
      )

      maxHeight = 0
    } else {
      if theme.memorizeSize && (vertical && position.midY / screenRect.height < 0.5) ||
          (vertical && position.minX + max(contentRect.width, maxHeight) + theme.edgeInset.width * 2 > screenRect.maxX) {
        if contentRect.width >= maxHeight {
          maxHeight = contentRect.width
        } else {
          contentRect.size.width = maxHeight
          if vertical {
            naturalPanelSize.height = contentRect.width + theme.edgeInset.width * 2 + view.pagingOffset
          } else {
            naturalPanelSize.width = contentRect.width + theme.edgeInset.width * 2 + view.pagingOffset
          }
        }
      }

      panelRect.size = naturalPanelSize

      if vertical {
        // Anchor vertical panels on one side of the cursor to avoid jumping while typing.
        if position.midY / screenRect.height >= 0.5 {
          panelRect.origin.y = position.minY - SquirrelTheme.offsetHeight - panelRect.height + view.pagingOffset
        } else {
          panelRect.origin.y = position.maxY + SquirrelTheme.offsetHeight
        }
        panelRect.origin.x = position.minX - panelRect.width - SquirrelTheme.offsetHeight
        if view.preeditRange.length > 0, let preeditTextRange = view.convert(range: view.preeditRange) {
          let preeditRect = view.contentRect(range: preeditTextRange)
          panelRect.origin.x += preeditRect.height + theme.edgeInset.width
        }
      } else {
        panelRect.origin = NSPoint(x: position.minX - view.pagingOffset, y: position.minY - SquirrelTheme.offsetHeight - panelRect.height)
      }

      if panelRect.maxX > screenRect.maxX { panelRect.origin.x = screenRect.maxX - panelRect.width }
      if panelRect.minX < screenRect.minX { panelRect.origin.x = screenRect.minX }
      if panelRect.minY < screenRect.minY {
        if vertical { panelRect.origin.y = screenRect.minY } else { panelRect.origin.y = position.maxY + SquirrelTheme.offsetHeight }
      }
      if panelRect.maxY > screenRect.maxY { panelRect.origin.y = screenRect.maxY - panelRect.height }
      if panelRect.minY < screenRect.minY { panelRect.origin.y = screenRect.minY }
    }

    let isScrollMode = scrollColumns > 0
    let currentlyScaled = contentView!.bounds.size != contentView!.frame.size
    let shouldAnimate = isVisible && !vertical && !requiresFullScreen && !currentlyScaled &&
      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && isScrollMode != wasScrollMode && panelRect.size != frame.size
    wasScrollMode = isScrollMode
    scrollAnimationGeneration &+= 1
    if shouldAnimate {
      let generation = scrollAnimationGeneration
      view.textView.frame = NSRect(x: view.pagingOffset, y: contentView!.bounds.height - naturalPanelSize.height,
                                   width: max(0, naturalPanelSize.width - view.pagingOffset), height: naturalPanelSize.height)
      view.textView.autoresizingMask = [.minYMargin]
      NSAnimationContext.runAnimationGroup { context in
        context.duration = SquirrelTheme.scrollAnimationDuration
        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        self.animator().setFrame(panelRect, display: true)
      } completionHandler: {
        DispatchQueue.main.async {
          guard self.scrollAnimationGeneration == generation else { return }
          self.layoutPanel(windowSize: panelRect.size, naturalPanelSize: naturalPanelSize, theme: self.view.currentTheme)
          self.invalidateShadow()
        }
      }
    } else {
      setFrame(panelRect, display: true)
      layoutPanel(windowSize: panelRect.size, naturalPanelSize: naturalPanelSize, theme: theme)
    }
    alphaValue = theme.alpha
    invalidateShadow()
    orderFront(nil)
    // voila!
  }

  func layoutPanel(windowSize: NSSize, naturalPanelSize: NSSize, theme: SquirrelTheme) {
    view.textView.autoresizingMask = []
    // Keep the window frame at the scaled physical size while drawing in natural coordinates through bounds.
    contentView!.frame = NSRect(origin: .zero, size: windowSize)
    contentView!.bounds = NSRect(origin: .zero, size: naturalPanelSize)

    if vertical {
      contentView!.boundsRotation = -90
      contentView!.setBoundsOrigin(NSPoint(x: 0, y: naturalPanelSize.width))
    } else {
      contentView!.boundsRotation = 0
      contentView!.setBoundsOrigin(.zero)
    }

    view.textView.boundsRotation = 0
    view.textView.setBoundsOrigin(.zero)

    // Subviews must read the post-rotation bounds; Cocoa adjusts the origin and swaps dimensions in vertical mode.
    let subviewFrame = contentView!.bounds
    view.frame = subviewFrame

    var textFrame = subviewFrame
    textFrame.size.width -= view.pagingOffset
    textFrame.origin.x += view.pagingOffset
    view.textView.frame = textFrame

    if theme.translucency {
      var backFrame = subviewFrame
      backFrame.size.width += view.pagingOffset
      back.frame = backFrame
      back.appearance = NSApp.effectiveAppearance
      back.isHidden = false
    } else {
      back.isHidden = true
    }
  }

  func show(status message: String) {
    scrollColumns = 0
    wasScrollMode = false
    scrollAnimationGeneration &+= 1
    view.textView.autoresizingMask = []
    let theme = view.currentTheme
    let text = NSMutableAttributedString(string: message, attributes: theme.attrs)
    text.addAttribute(.paragraphStyle, value: theme.paragraphStyle, range: NSRange(location: 0, length: text.length))
    view.textContentStorage.attributedString = text
    view.textView.setLayoutOrientation(vertical ? .vertical : .horizontal)
    view.drawView(candidateRanges: [NSRange(location: 0, length: text.length)], hilightedIndex: -1,
                  preeditRange: .empty, highlightedPreeditRange: .empty, canPageUp: false, canPageDown: false)
    show()

    statusTimer?.invalidate()
    statusTimer = Timer.scheduledTimer(withTimeInterval: SquirrelTheme.showStatusDuration, repeats: false) { _ in
      self.hide()
    }
  }

  func buildCandidateLine(candidateIndex i: Int, highlightedIndex: Int, theme: SquirrelTheme,
                          scrollColumns: Int, highlightedRow: Int) -> NSMutableAttributedString {
    let attrs = i == highlightedIndex ? theme.highlightedAttrs : theme.attrs
    let labelAttrs = i == highlightedIndex ? theme.labelHighlightedAttrs : theme.labelAttrs
    var commentAttrs = i == highlightedIndex ? theme.commentHighlightedAttrs : theme.commentAttrs

    let column = scrollColumns > 0 ? i % scrollColumns : i
    let row = scrollColumns > 0 ? i / scrollColumns : 0
    let label = if theme.candidateFormat.contains(/\[label\]/) {
      if labels.count > 1 && column < labels.count {
        labels[column]
      } else if labels.count == 1 && column < labels.first!.count {
        String(labels.first![labels.first!.index(labels.first!.startIndex, offsetBy: column)])
      } else {
        "\(column + 1)"
      }
    } else {
      ""
    }

    let candidate = candidates[i].precomposedStringWithCanonicalMapping
    let comment = comments[i].precomposedStringWithCanonicalMapping

    var formatAttrs = labelAttrs
    if scrollColumns > 0 && row != highlightedRow {
      formatAttrs[.foregroundColor] = NSColor.clear
    }
    let line = NSMutableAttributedString(string: theme.candidateFormat, attributes: formatAttrs)
    let candidateText = NSMutableAttributedString(string: candidate, attributes: attrs)
    if candidate.count <= 5 {
      preventLineBreaks(in: candidateText)
    }
    // Apply semantic accent/warning colors only for non-highlighted rows
    if let inputController, !inputController.specialCommentIndices.isEmpty && i != highlightedIndex && (scrollColumns == 0 || row == highlightedRow) {
      if let accent = inputController.specialCommentIndices[.commentHighlight], accent.contains(column) {
        commentAttrs[.foregroundColor] = theme.accentCommentTextColor
      } else if let warning = inputController.specialCommentIndices[.commentWarning], warning.contains(column) {
        commentAttrs[.foregroundColor] = theme.warningCommentTextColor
      }
    }
    let labelText = NSAttributedString(string: label, attributes: formatAttrs)
    let commentText = NSAttributedString(string: comment, attributes: commentAttrs)
    replace(placeholder: "[label]", in: line, with: labelText)
    let labeledLine = line.copy() as! NSAttributedString
    replace(placeholder: "[candidate]", in: line, with: candidateText)
    replace(placeholder: "[comment]", in: line, with: commentText)

    if line.length <= 10 {
      preventLineBreaks(in: line)
    }

    if !linear, let labelEnd = labeledLine.string.firstMatch(of: /\[(candidate|comment)\]/)?.range.lowerBound {
      let labelString = labeledLine.attributedSubstring(from: NSRange(location: 0, length: labelEnd.utf16Offset(in: labeledLine.string)))
      let labelWidth = labelString.boundingRect(with: .zero, options: [.usesLineFragmentOrigin]).width
      let style = (i == 0 ? theme.firstParagraphStyle : theme.paragraphStyle).mutableCopy() as! NSMutableParagraphStyle
      style.headIndent = labelWidth
      line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
    }
    return line
  }

  func scrollTabStops(for lines: [NSAttributedString], scrollColumns: Int, theme: SquirrelTheme) -> [NSTextTab] {
    let activeColumns = min(scrollColumns, lines.count)
    guard activeColumns > 1 else { return [] }
    let minColumnWidth = ceil(theme.font.pointSize * 2.6)
    var columnWidths = Array(repeating: minColumnWidth, count: activeColumns)
    let measureSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    for idx in 0..<lines.count {
      let col = idx % scrollColumns
      guard col < activeColumns else { continue }
      let rectWidth = ceil(lines[idx].boundingRect(with: measureSize, options: [.usesLineFragmentOrigin, .usesFontLeading]).width)
      let sizeWidth = ceil(lines[idx].size().width)
      columnWidths[col] = max(columnWidths[col], rectWidth, sizeWidth)
    }

    let baseGap = max(view.separatorWidth * 2, ceil(theme.font.pointSize * 1.25))
    let maxAllowedWidth = maxTextWidth()
    let totalContentWidth = columnWidths.reduce(0, +)
    let minGap = view.separatorWidth + 2
    let columnGap = if totalContentWidth + baseGap * CGFloat(activeColumns - 1) > maxAllowedWidth {
      max(minGap, floor((maxAllowedWidth - totalContentWidth) / CGFloat(activeColumns - 1)))
    } else {
      baseGap
    }

    var tabStops = [NSTextTab]()
    var tabX: CGFloat = 0
    for col in 0..<(activeColumns - 1) {
      tabX += columnWidths[col] + columnGap
      tabStops.append(NSTextTab(textAlignment: .left, location: tabX))
    }
    return tabStops
  }

  func replace(placeholder: String, in text: NSMutableAttributedString, with replacement: NSAttributedString) {
    let string = text.string
    for range in string.ranges(of: placeholder).reversed() {
      text.replaceCharacters(in: convert(range: range, in: string), with: replacement)
    }
  }

  func preventLineBreaks(in text: NSMutableAttributedString) {
    let string = text.string
    let range = convert(range: string.dropFirst().startIndex..<string.endIndex, in: string)
    text.addAttribute(.noBreak, value: true, range: range)
  }

  func convert(range: Range<String.Index>, in string: String) -> NSRange {
    let startPos = range.lowerBound.utf16Offset(in: string)
    let endPos = range.upperBound.utf16Offset(in: string)
    return NSRange(location: startPos, length: endPos - startPos)
  }

  static func makeBackgroundView() -> NSView {
    if #available(macOS 26.0, *) {
      let glassView = NSGlassEffectView()
      glassView.style = .clear
      return glassView
    } else {
      let visualEffectView = NSVisualEffectView()
      visualEffectView.blendingMode = .behindWindow
      visualEffectView.material = .hudWindow
      visualEffectView.state = .active
      return visualEffectView
    }
  }
}
