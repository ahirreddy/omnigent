//! The Inbox's preview of an unread session: its latest agent output.
//!
//! As the web's `latestOutput` (`web/src/lib/lastAssistantText.ts`), the newest assistant text or
//! error among the session's last items, cut to a few lines.

use omnigent_protocol::items::{ErrorLevel, ItemData, MessageRole};
use omnigent_protocol::{ConversationItem, content::ContentPart, content::TextPartKind};

use super::{ClientCore, SessionError};
use crate::http::HttpTransport;

/// Enough trailing items to step past a tool call or two after the final reply.
const SCAN_ITEMS: u32 = 12;
/// The preview's character budget.
const PREVIEW_CHARS: usize = 280;
/// The preview's line budget.
const PREVIEW_LINES: usize = 3;

/// A session's latest output.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LatestOutput {
    /// The item it came from, to tell a newer answer apart.
    pub item_id: String,
    /// The first lines, cut to the budget.
    pub preview: String,
    /// The whole text when the preview cut some of it.
    pub full_text: Option<String>,
}

fn assistant_text(data: &ItemData) -> Option<String> {
    match data {
        ItemData::Message(message) if message.role == MessageRole::Assistant => {
            let text: String = message
                .content
                .iter()
                .filter_map(|part| match part {
                    ContentPart::Text {
                        kind: TextPartKind::OutputText,
                        text,
                    } => Some(text.as_str()),
                    _ => None,
                })
                .collect();
            let text = text.trim();
            (!text.is_empty()).then(|| text.to_owned())
        }
        ItemData::Error(error) if error.level != Some(ErrorLevel::Info) => {
            [error.title.as_deref(), Some(error.message.as_str())]
                .into_iter()
                .flatten()
                .map(str::trim)
                .find(|text| !text.is_empty())
                .map(str::to_owned)
        }
        _ => None,
    }
}

/// The first `lines` non-empty lines of `text`, cut to `chars` characters with an ellipsis.
#[must_use]
pub fn preview_text(text: &str, chars: usize, lines: usize) -> String {
    let joined = text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .take(lines)
        .collect::<Vec<_>>()
        .join("\n");
    if joined.chars().count() <= chars {
        return joined;
    }
    let cut: String = joined.chars().take(chars.saturating_sub(1)).collect();
    format!("{}\u{2026}", cut.trim_end())
}

/// The newest output among `items` (oldest first), or `None` when none carries any.
#[must_use]
pub fn latest_output(items: &[ConversationItem]) -> Option<LatestOutput> {
    items.iter().rev().find_map(|item| {
        let text = assistant_text(&item.data)?;
        let preview = preview_text(&text, PREVIEW_CHARS, PREVIEW_LINES);
        let whole = preview_text(&text, usize::MAX, usize::MAX);
        Some(LatestOutput {
            item_id: item.id.clone(),
            full_text: (preview != whole).then_some(text),
            preview,
        })
    })
}

impl<T: HttpTransport> ClientCore<T> {
    /// `session_id`'s latest agent output, from its newest items.
    ///
    /// # Errors
    ///
    /// As [`Self::history_page`].
    #[allow(
        clippy::future_not_send,
        reason = "Send-ness follows the host transport; WASM transports are !Send by design"
    )]
    pub async fn latest_output(
        &self,
        session_id: &str,
    ) -> Result<Option<LatestOutput>, SessionError> {
        let page = self.history_page(session_id, None, SCAN_ITEMS).await?;
        Ok(latest_output(&page.items))
    }
}

#[cfg(test)]
mod tests {
    use futures::executor::block_on;

    use super::super::test_support::{RouteTransport, connected};
    use super::*;

    #[test]
    fn only_output_text_counts_as_the_reply() {
        let item: ConversationItem = serde_json::from_value(serde_json::json!({
            "id": "a", "type": "message", "role": "assistant",
            "content": [
                {"type": "input_text", "text": "typed"},
                {"type": "output_text", "text": "said"},
            ],
        }))
        .unwrap();
        assert_eq!(latest_output(&[item]).unwrap().preview, "said");
    }

    #[test]
    fn previews_cut_lines_and_characters() {
        assert_eq!(preview_text("\n a \n\n b \n c \n d", 100, 3), "a\nb\nc");
        assert_eq!(preview_text("abcdef", 4, 3), "abc\u{2026}");
        assert_eq!(preview_text("abc", 3, 3), "abc");
    }

    #[test]
    fn the_newest_reply_or_error_wins_over_tool_calls() {
        let transport = RouteTransport::local();
        transport.ok(
            "/v1/sessions/s1/items",
            r#"{"data":[
              {"id":"i4","type":"function_call","name":"ls","call_id":"c","arguments":"{}"},
              {"id":"i3","type":"message","role":"assistant","content":[{"type":"output_text","text":"Done.\nAll 24 tests pass."}]},
              {"id":"i2","type":"message","role":"user","content":[{"type":"input_text","text":"go"}]}
            ],"has_more":false}"#,
        );
        transport.ok(
            "/v1/sessions/s2/items",
            r#"{"data":[
              {"id":"e1","type":"error","code":"x","message":"Runner exited","level":"error"},
              {"id":"e0","type":"error","code":"y","message":"FYI","level":"info"}
            ],"has_more":false}"#,
        );
        transport.ok(
            "/v1/sessions/s3/items",
            r#"{"data":[{"id":"u1","type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}],"has_more":false}"#,
        );
        let core = connected(transport);
        let reply = block_on(core.latest_output("s1")).unwrap().unwrap();
        assert_eq!(reply.item_id, "i3");
        assert_eq!(reply.preview, "Done.\nAll 24 tests pass.");
        assert_eq!(reply.full_text, None);
        let error = block_on(core.latest_output("s2")).unwrap().unwrap();
        assert_eq!(error.preview, "Runner exited");
        assert_eq!(block_on(core.latest_output("s3")), Ok(None));
    }
}
