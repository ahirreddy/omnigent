//! A composer draft that quotes transcript text (the web's `replyDraft`): quote blocks, each
//! after the text typed before it, then the reply. It is sent as Markdown block quotes.

/// One quoted selection and the text typed before it.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash)]
pub struct ReplyQuote {
    /// The text typed before the quote.
    pub before: String,
    /// The quoted text, with `\n` line breaks.
    pub text: String,
}

/// A draft with quote blocks.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash)]
pub struct ReplyDraft {
    /// The quotes, in order.
    pub quotes: Vec<ReplyQuote>,
    /// The text after the last quote.
    pub text: String,
}

impl ReplyDraft {
    /// The message text: each quote's leading text, then the quote as a Markdown block quote,
    /// then the reply, a blank line apart (web `serializeReplyDraft`).
    #[must_use]
    pub fn message(&self) -> String {
        if self.quotes.is_empty() {
            return self.text.clone();
        }
        let mut parts: Vec<String> = Vec::with_capacity(self.quotes.len() * 2 + 1);
        for quote in &self.quotes {
            parts.push(quote.before.clone());
            parts.push(
                quote
                    .text
                    .split('\n')
                    .map(|line| format!("> {line}"))
                    .collect::<Vec<_>>()
                    .join("\n"),
            );
        }
        parts.push(self.text.clone());
        join_paragraphs(&parts)
    }

    /// The draft with `selection` quoted after its text, which moves before the quote; the reply
    /// starts empty (web `appendReplyQuote`). A blank selection changes nothing.
    #[must_use]
    pub fn quoting(&self, selection: &str) -> Self {
        let selection = selection.replace("\r\n", "\n").replace('\r', "\n");
        let selection = selection.trim_matches('\n');
        if selection.trim().is_empty() {
            return self.clone();
        }
        let mut quotes = self.quotes.clone();
        quotes.push(ReplyQuote {
            before: self.text.clone(),
            text: selection.to_owned(),
        });
        Self {
            quotes,
            text: String::new(),
        }
    }

    /// The draft without quote `index`; its leading text joins the text after it (web
    /// `removeReplyQuote`). An index past the end changes nothing.
    #[must_use]
    pub fn removing(&self, index: usize) -> Self {
        if index >= self.quotes.len() {
            return self.clone();
        }
        let mut draft = self.clone();
        let removed = draft.quotes.remove(index);
        if let Some(next) = draft.quotes.get_mut(index) {
            next.before = join_paragraphs(&[removed.before, std::mem::take(&mut next.before)]);
        } else {
            draft.text = join_paragraphs(&[removed.before, draft.text]);
        }
        draft
    }
}

/// `parts` joined so each starts a new paragraph: a blank line between non-empty parts,
/// counting the line breaks they already end or start with (web `joinParagraphs`).
fn join_paragraphs(parts: &[String]) -> String {
    let mut joined = String::new();
    for part in parts {
        if joined.is_empty() || part.is_empty() {
            joined.push_str(part);
            continue;
        }
        let breaks = edge_breaks(joined.chars().rev()) + edge_breaks(part.chars());
        joined.push_str(&"\n".repeat(2usize.saturating_sub(breaks)));
        joined.push_str(part);
    }
    joined
}

/// The line breaks (at most two, `\r\n` counting once) at the edge `chars` walks from.
fn edge_breaks(chars: impl Iterator<Item = char>) -> usize {
    let mut breaks = 0;
    for character in chars {
        match character {
            '\n' if breaks < 2 => breaks += 1,
            '\r' => {}
            _ => break,
        }
        if breaks == 2 {
            break;
        }
    }
    breaks
}

#[cfg(test)]
mod tests {
    use super::*;

    fn quote(before: &str, text: &str) -> ReplyQuote {
        ReplyQuote {
            before: before.into(),
            text: text.into(),
        }
    }

    #[test]
    fn a_quote_is_sent_as_a_block_quote_a_paragraph_apart() {
        let draft = ReplyDraft::default().quoting("one\r\ntwo\n");
        assert_eq!(draft.quotes, [quote("", "one\ntwo")]);
        assert_eq!(draft.message(), "> one\n> two");
        let replied = ReplyDraft {
            text: "Why?".into(),
            ..draft
        };
        assert_eq!(replied.message(), "> one\n> two\n\nWhy?");
    }

    #[test]
    fn quoting_moves_the_typed_text_before_the_quote() {
        let draft = ReplyDraft {
            quotes: vec![],
            text: "Look:\n".into(),
        }
        .quoting("x");
        assert_eq!(draft.quotes, [quote("Look:\n", "x")]);
        assert_eq!(draft.text, "");
        assert_eq!(draft.message(), "Look:\n\n> x");
        let twice = draft.quoting("y");
        assert_eq!(twice.message(), "Look:\n\n> x\n\n> y");
        assert_eq!(draft.quoting(" \n "), draft);
    }

    #[test]
    fn removing_a_quote_keeps_the_text_around_it() {
        let draft = ReplyDraft {
            quotes: vec![quote("first", "a"), quote("second", "b")],
            text: "reply".into(),
        };
        let without_first = draft.removing(0);
        assert_eq!(without_first.quotes, [quote("first\n\nsecond", "b")]);
        let without_last = draft.removing(1);
        assert_eq!(without_last.quotes, [quote("first", "a")]);
        assert_eq!(without_last.text, "second\n\nreply");
        assert_eq!(draft.removing(5), draft);
        assert_eq!(
            draft.removing(0).removing(0).message(),
            "first\n\nsecond\n\nreply"
        );
    }
}
