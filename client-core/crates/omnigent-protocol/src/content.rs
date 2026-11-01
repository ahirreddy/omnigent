//! Message content blocks (`MessageData.content`, pending inputs).
//!
//! Private reasoning blocks and hidden context are reduced to their type at decode time, and
//! embedded attachment bytes are never kept, so nothing private can reach a view or a log through
//! these models.

use serde::ser::SerializeMap;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{Map, Value};

use crate::display;
use crate::error::DecodeError;
use crate::wire_enum::wire_enum;

wire_enum! {
    /// The block type of a [`ContentPart::Text`].
    pub enum TextPartKind {
        /// `input_text` (user input).
        InputText = "input_text",
        /// `output_text` (assistant output).
        OutputText = "output_text",
        /// `text` (generic; also a bare string `content`).
        Text = "text",
        /// `refusal`: the model declined; the text is in the `refusal` key.
        Refusal = "refusal",
    }
}

/// What an attachment block holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AttachmentKind {
    /// An image.
    Image,
    /// Any other file.
    File,
    /// Audio.
    Audio,
    /// Video.
    Video,
}

/// One content block of a message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ContentPart {
    /// Visible text, including refusals.
    Text {
        /// The block type.
        kind: TextPartKind,
        /// The text.
        text: String,
    },
    /// An image, file, audio or video reference.
    Attachment(AttachmentPart),
    /// Private reasoning or hidden context. Only the block type is kept; it is never displayed.
    Private {
        /// The block type, for example `thinking`.
        part_type: String,
    },
    /// A block type this client does not know.
    Unknown {
        /// The block type.
        part_type: String,
        /// The block's sanitised, bounded display text (see [`display::safe_display_text`]).
        detail: String,
    },
}

/// A display-only descriptor of an attached file. Embedded bytes are dropped at decode; views must
/// not fetch arbitrary references automatically.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttachmentPart {
    /// The block type as sent, for example `input_image`.
    #[serde(rename = "type")]
    pub part_type: String,
    /// What the block holds.
    pub kind: AttachmentKind,
    /// The session file id, when the block references an uploaded file.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_id: Option<String>,
    /// A non-embedded URL reference (never a `data:` URL).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    /// The file name, when sent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub filename: Option<String>,
    /// The media type, when sent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mime_type: Option<String>,
    /// The block carried its bytes inline (they were dropped).
    #[serde(default, skip_serializing_if = "crate::field::is_false")]
    pub embedded: bool,
}

impl AttachmentPart {
    /// The display-only reference: the file id, else a non-embedded URL.
    #[must_use]
    pub fn reference(&self) -> Option<&str> {
        self.file_id.as_deref().or(self.url.as_deref())
    }
}

const ATTACHMENT_TYPES: &[&str] = &[
    "input_image",
    "output_image",
    "image",
    "image_url",
    "input_file",
    "output_file",
    "file",
    "input_audio",
    "output_audio",
    "audio",
    "input_video",
    "output_video",
    "video",
];

impl ContentPart {
    /// Decodes one block.
    ///
    /// # Errors
    ///
    /// The block is not an object, has no string `type`, or is a text block without its text.
    pub fn from_value(value: Value) -> Result<Self, DecodeError> {
        let Value::Object(fields) = value else {
            return Err(DecodeError::NotAnObject {
                context: "content block".to_owned(),
            });
        };
        let Some(Value::String(part_type)) = fields.get("type") else {
            return Err(DecodeError::missing("content block", "type"));
        };
        let part_type = part_type.clone();
        if display::is_hidden_object(&fields)
            || display::is_private_content_type(&part_type)
            || fields.get("private") == Some(&Value::Bool(true))
        {
            return Ok(Self::Private { part_type });
        }
        let kind = TextPartKind::parse(&part_type);
        if !kind.is_unknown() {
            let key = if kind == TextPartKind::Refusal {
                "refusal"
            } else {
                "text"
            };
            let Some(Value::String(text)) = fields.get(key) else {
                return Err(DecodeError::missing(format!("`{part_type}` block"), key));
            };
            return Ok(Self::Text {
                kind,
                text: text.clone(),
            });
        }
        if ATTACHMENT_TYPES.contains(&part_type.as_str()) {
            return Ok(Self::Attachment(attachment(part_type, &fields)));
        }
        let detail = display::safe_display_text(&Value::Object(fields));
        Ok(Self::Unknown { part_type, detail })
    }

    /// The visible text of a text or refusal block.
    #[must_use]
    pub fn text(&self) -> Option<&str> {
        match self {
            Self::Text { text, .. } => Some(text),
            Self::Attachment(_) | Self::Private { .. } | Self::Unknown { .. } => None,
        }
    }

    /// The block type.
    #[must_use]
    pub fn part_type(&self) -> &str {
        match self {
            Self::Text { kind, .. } => kind.as_str(),
            Self::Attachment(part) => &part.part_type,
            Self::Private { part_type } | Self::Unknown { part_type, .. } => part_type,
        }
    }
}

fn attachment(part_type: String, fields: &Map<String, Value>) -> AttachmentPart {
    let kind = if part_type.contains("image") {
        AttachmentKind::Image
    } else if part_type.contains("audio") {
        AttachmentKind::Audio
    } else if part_type.contains("video") {
        AttachmentKind::Video
    } else {
        AttachmentKind::File
    };
    let string = |key: &str| fields.get(key).and_then(Value::as_str).map(str::to_owned);
    let source = fields.get("source").and_then(Value::as_object);
    let image_url = fields.get("image_url");
    let raw_url = string("file_url")
        .or_else(|| image_url.and_then(Value::as_str).map(str::to_owned))
        .or_else(|| {
            image_url
                .and_then(|url| url.get("url"))
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .or_else(|| string("url"))
        .or_else(|| {
            source
                .and_then(|source| source.get("url"))
                .and_then(Value::as_str)
                .map(str::to_owned)
        });
    let present = |value: Option<&Value>| value.is_some_and(|value| !value.is_null());
    let embedded = raw_url
        .as_deref()
        .is_some_and(|url| url.to_lowercase().starts_with("data:"))
        || present(fields.get("file_data"))
        || present(fields.get("data"))
        || present(source.and_then(|source| source.get("data")))
        || fields.get("embedded") == Some(&Value::Bool(true));
    AttachmentPart {
        part_type,
        kind,
        file_id: string("file_id"),
        url: if embedded { None } else { raw_url },
        filename: string("filename").or_else(|| string("name")),
        mime_type: string("mime_type")
            .or_else(|| string("media_type"))
            .or_else(|| {
                source
                    .and_then(|source| source.get("media_type"))
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            }),
        embedded,
    }
}

impl Serialize for ContentPart {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::Text { kind, text } => {
                let mut map = serializer.serialize_map(Some(2))?;
                map.serialize_entry("type", kind)?;
                let key = if *kind == TextPartKind::Refusal {
                    "refusal"
                } else {
                    "text"
                };
                map.serialize_entry(key, text)?;
                map.end()
            }
            Self::Attachment(part) => part.serialize(serializer),
            Self::Private { part_type } => {
                let mut map = serializer.serialize_map(Some(2))?;
                map.serialize_entry("type", part_type)?;
                map.serialize_entry("private", &true)?;
                map.end()
            }
            Self::Unknown { part_type, detail } => {
                let mut map = serializer.serialize_map(Some(2))?;
                map.serialize_entry("type", part_type)?;
                map.serialize_entry("detail", detail)?;
                map.end()
            }
        }
    }
}

impl<'de> Deserialize<'de> for ContentPart {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Self::from_value(Value::deserialize(deserializer)?).map_err(serde::de::Error::custom)
    }
}

/// Decodes `content`: a list of blocks, or (older payloads) a bare string, which becomes one
/// `text` block. Anything else is an error.
pub(crate) fn content_parts<'de, D: Deserializer<'de>>(
    deserializer: D,
) -> Result<Vec<ContentPart>, D::Error> {
    match Value::deserialize(deserializer)? {
        Value::String(text) => Ok(vec![ContentPart::Text {
            kind: TextPartKind::Text,
            text,
        }]),
        Value::Array(values) => values
            .into_iter()
            .map(|value| ContentPart::from_value(value).map_err(serde::de::Error::custom))
            .collect(),
        other => Err(serde::de::Error::custom(format!(
            "content must be a list of blocks or a string, not {}",
            json_kind(&other)
        ))),
    }
}

/// The visible text of some blocks: text and refusal blocks joined with newlines.
#[must_use]
pub fn visible_text(parts: &[ContentPart]) -> String {
    parts
        .iter()
        .filter_map(ContentPart::text)
        .collect::<Vec<_>>()
        .join("\n")
}

pub(crate) const fn json_kind(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "a boolean",
        Value::Number(_) => "a number",
        Value::String(_) => "a string",
        Value::Array(_) => "an array",
        Value::Object(_) => "an object",
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn part(value: Value) -> ContentPart {
        ContentPart::from_value(value).unwrap()
    }

    #[test]
    fn text_and_refusal_blocks_keep_their_text() {
        assert_eq!(
            part(json!({"type": "refusal", "refusal": "No."})).text(),
            Some("No.")
        );
        assert!(ContentPart::from_value(json!({"type": "output_text"})).is_err());
        assert!(ContentPart::from_value(json!({"text": "untyped"})).is_err());
        assert!(ContentPart::from_value(json!("bare")).is_err());
    }

    #[test]
    fn hidden_and_private_blocks_keep_only_their_type() {
        for value in [
            json!({"type": "thinking", "thinking": "PRIVATE"}),
            json!({"type": "redacted_thinking", "data": "PRIVATE"}),
            json!({"type": "input_text", "text": "PRIVATE", "is_meta": true}),
        ] {
            let decoded = part(value);
            assert!(
                matches!(decoded, ContentPart::Private { .. }),
                "{decoded:?}"
            );
            assert!(!serde_json::to_string(&decoded).unwrap().contains("PRIVATE"));
        }
    }

    #[test]
    fn image_url_object_and_source_url_are_references() {
        let image =
            part(json!({"type": "image_url", "image_url": {"url": "https://x.test/a.png"}}));
        let ContentPart::Attachment(image) = image else {
            panic!("{image:?}")
        };
        assert_eq!(image.reference(), Some("https://x.test/a.png"));
        assert!(!image.embedded);
    }
}
