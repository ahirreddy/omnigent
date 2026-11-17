#if os(macOS)
  import AppKit
  import SwiftUI

  /// Where a text cell puts what it shows, as ``TranscriptTableTextFrames`` says.
  extension TranscriptTableTextCell {
    /// Places the text, the parts beside it, the bubble and the footer; returns the row's
    /// height.
    func layOutContent(
      metrics: TranscriptTableTextMetrics, textWidth: CGFloat, message: TranscriptTableTextMessage
    ) -> CGFloat {
      switch message.role {
      case .answer: layOutAnswer(metrics: metrics, textWidth: textWidth, message: message)
      case .user: layOutPrompt(metrics: metrics, textWidth: textWidth, message: message)
      }
    }

    /// An answer: its runs down the column, then its footer.
    private func layOutAnswer(
      metrics: TranscriptTableTextMetrics, textWidth: CGFloat, message: TranscriptTableTextMessage
    ) -> CGFloat {
      bubbleView.isHidden = true
      if let palette = style.palette, textWidth >= MessageTextContentView.minimumWidth {
        // The answers after this one lay out (and draw) ahead at this width.
        MessageTextPrewarm.shared.note(
          palette: palette, width: textWidth, scale: style.drawsAhead ? style.scale : 0,
          raster: style.drawsAhead ? style.rasterStyle : nil)
      }
      let frames = TranscriptTableTextFrames(
        role: .answer, gaps: message.gaps,
        sizes: entrySizes(of: message, textWidth: textWidth, fillsWidth: true), metrics: metrics,
        workedHeight: message.decoration.workedFor.map { _ in Self.workedLabelHeight })
      place(frames, message: message)
      if let workedFor = message.decoration.workedFor, let frame = frames.worked {
        let label = workedLabel ?? makeWorkedLabel()
        label.stringValue = TurnElapsed.worked(workedFor)
        label.toolTip = message.decoration.timestamp.map {
          "Finished \(MessageTimestamp.format($0, now: Date()))"
        }
        label.frame = frame
        label.isHidden = false
      } else {
        workedLabel?.isHidden = true
      }
      return frames.height
    }

    /// A user's prompt: its runs in a bubble that hugs them, at the column's trailing edge.
    private func layOutPrompt(
      metrics: TranscriptTableTextMetrics, textWidth: CGFloat, message: TranscriptTableTextMessage
    ) -> CGFloat {
      workedLabel?.isHidden = true
      if let palette = style.palette, textWidth >= MessageTextContentView.minimumWidth {
        // The prompts after this one draw ahead at this width.
        MessageTextPrewarm.prompts.note(
          palette: palette, width: textWidth, scale: style.drawsAhead ? style.scale : 0,
          raster: style.drawsAhead ? style.rasterStyle : nil)
      }
      // What shows under the bubble is the last part hosted.
      let below = message.belowBubble == nil ? nil : accessoryViews.last
      let frames = TranscriptTableTextFrames(
        role: .user, gaps: message.gaps,
        sizes: entrySizes(of: message, textWidth: textWidth, fillsWidth: false),
        metrics: metrics, workedHeight: nil, belowBubbleSize: below?.idealSize)
      place(frames, message: message)
      if let below, let frame = frames.belowBubble { below.frame = frame }
      if let bubble = frames.bubble {
        bubbleView.frame = bubble
        bubbleView.color = style.bubble
        bubbleView.isHidden = false
      }
      return frames.height
    }

    /// Each of `message`'s entries' sizes at `textWidth`: as wide as that when they fill it, else
    /// as their own.
    private func entrySizes(
      of message: TranscriptTableTextMessage, textWidth: CGFloat, fillsWidth: Bool
    ) -> [CGSize] {
      var runs = runs.makeIterator()
      var accessories = accessoryViews.makeIterator()
      return message.entries.map { entry in
        switch entry {
        case .piece:
          return runs.next()?.size(for: textWidth, fillsWidth: fillsWidth) ?? .zero
        case .accessory:
          guard let size = accessories.next()?.idealSize else { return .zero }
          return CGSize(
            width: fillsWidth ? textWidth : min(textWidth, size.width), height: size.height)
        case .empty:
          return .zero
        }
      }
    }

    /// Puts the runs and the parts beside them where `frames` says, and the actions' row.
    private func place(_ frames: TranscriptTableTextFrames, message: TranscriptTableTextMessage) {
      var runs = runs.makeIterator()
      var accessories = accessoryViews.makeIterator()
      for (entry, frame) in zip(message.entries, frames.entries) {
        switch entry {
        case .piece: runs.next()?.view.frame = frame
        case .accessory: accessories.next()?.frame = frame
        case .empty: break
        }
      }
      actionsTop = frames.actionsTop
      actionsLineHeight = frames.actionsLineHeight
      actionsTrailing = frames.actionsTrailing
      if contentFrame != frames.content {
        contentFrame = frames.content
        noteFocusRingMaskChanged()
        if flashingRowID != nil { flashView?.frame = flashFrame }
      }
    }

    /// The "Worked for" line's height: its caption's.
    static let workedLabelHeight: CGFloat = {
      let label = NSTextField(labelWithString: "Worked for 1s")
      label.font = .preferredFont(forTextStyle: .caption1)
      return label.intrinsicContentSize.height.rounded(.up)
    }()

    private func makeWorkedLabel() -> NSTextField {
      let label = NSTextField(labelWithString: "")
      label.font = .preferredFont(forTextStyle: .caption1)
      label.textColor = .secondaryLabelColor
      label.setAccessibilityIdentifier("worked-for")
      addSubview(label)
      workedLabel = label
      return label
    }
  }
#endif
