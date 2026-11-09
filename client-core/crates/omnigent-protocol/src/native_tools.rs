//! Provider-native tool items: the inner `OpenAI` Responses item of a `native_tool` item.
//!
//! The inner shapes belong to the provider and vary by version, so the item keeps every field and
//! exposes typed accessors for the parts clients show.

use serde::{Serialize, Serializer};
use serde_json::{Map, Value};

use crate::display;
use crate::error::DecodeError;
use crate::wire_enum::wire_enum;

wire_enum! {
    /// The inner item `type` of a native tool call.
    pub enum NativeToolKind {
        /// `web_search_call`.
        WebSearchCall = "web_search_call",
        /// `file_search_call`.
        FileSearchCall = "file_search_call",
        /// `code_interpreter_call`.
        CodeInterpreterCall = "code_interpreter_call",
        /// `computer_call`.
        ComputerCall = "computer_call",
        /// `image_generation_call`.
        ImageGenerationCall = "image_generation_call",
        /// `mcp_call`.
        McpCall = "mcp_call",
        /// `mcp_list_tools`.
        McpListTools = "mcp_list_tools",
    }
}

/// A provider tool item. `fields` is the whole inner object, including `type`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NativeToolItem {
    /// The inner item type.
    pub kind: NativeToolKind,
    /// Every field of the inner item, as sent.
    pub fields: Map<String, Value>,
}

impl NativeToolItem {
    /// Decodes an inner provider item.
    ///
    /// # Errors
    ///
    /// The item has no string `type`.
    pub fn from_fields(fields: Map<String, Value>) -> Result<Self, DecodeError> {
        let Some(Value::String(item_type)) = fields.get("type") else {
            return Err(DecodeError::missing("native tool item", "type"));
        };
        Ok(Self {
            kind: NativeToolKind::parse(item_type),
            fields,
        })
    }

    fn string(&self, key: &str) -> Option<&str> {
        self.fields.get(key).and_then(Value::as_str)
    }

    /// The provider's item id.
    #[must_use]
    pub fn id(&self) -> Option<&str> {
        self.string("id")
    }

    /// The provider call id.
    #[must_use]
    pub fn call_id(&self) -> Option<&str> {
        self.string("call_id")
    }

    /// The provider status, for example `completed`.
    #[must_use]
    pub fn status(&self) -> Option<&str> {
        self.string("status")
    }

    /// `mcp_call` tool name.
    #[must_use]
    pub fn name(&self) -> Option<&str> {
        self.string("name")
    }

    /// `mcp_call` / `mcp_list_tools` server label.
    #[must_use]
    pub fn server_label(&self) -> Option<&str> {
        self.string("server_label")
    }

    /// The field that best describes what the call did (for example a web search query), before
    /// sanitising. Use [`NativeToolItem::safe_summary`] for display.
    #[must_use]
    pub fn summary_value(&self) -> Option<&Value> {
        let field = |key: &str| self.fields.get(key).filter(|value| !value.is_null());
        let action = |key: &str| {
            self.fields
                .get("action")
                .and_then(|action| action.get(key))
                .filter(|value| !value.is_null())
        };
        match self.kind {
            NativeToolKind::WebSearchCall => action("query")
                .or_else(|| action("url"))
                .or_else(|| action("pattern")),
            NativeToolKind::FileSearchCall => field("queries"),
            NativeToolKind::CodeInterpreterCall => field("code"),
            NativeToolKind::ComputerCall => field("action"),
            NativeToolKind::ImageGenerationCall => {
                field("revised_prompt").or_else(|| field("prompt"))
            }
            NativeToolKind::McpCall => field("arguments").or_else(|| field("server_label")),
            NativeToolKind::McpListTools => field("server_label"),
            NativeToolKind::Unknown { .. } => None,
        }
    }

    /// The sanitised display text of [`NativeToolItem::summary_value`].
    #[must_use]
    pub fn safe_summary(&self) -> Option<String> {
        self.summary_value().map(display::safe_display_text)
    }

    /// The sanitised display text of the whole item, without generated image bytes.
    #[must_use]
    pub fn safe_detail(&self) -> String {
        let mut fields = self.fields.clone();
        if self.kind == NativeToolKind::ImageGenerationCall {
            fields.remove("result");
        }
        display::safe_display_text(&Value::Object(fields))
    }

    /// True for an `image_generation_call` that carries a generated image.
    #[must_use]
    pub fn has_generated_image(&self) -> bool {
        self.kind == NativeToolKind::ImageGenerationCall
            && match self.fields.get("result") {
                None | Some(Value::Null) => false,
                Some(Value::String(result)) => !result.is_empty(),
                Some(_) => true,
            }
    }
}

impl Serialize for NativeToolItem {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        self.fields.serialize(serializer)
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn item(value: &Value) -> NativeToolItem {
        NativeToolItem::from_fields(value.as_object().unwrap().clone()).unwrap()
    }

    #[test]
    fn identity_fields_read_back() {
        let mcp = item(&json!({"type": "mcp_call", "id": "m1", "server_label": "docs"}));
        assert_eq!(mcp.id(), Some("m1"));
        assert_eq!(mcp.server_label(), Some("docs"));
    }

    #[test]
    fn an_unknown_tool_has_no_summary_field() {
        assert_eq!(
            item(&json!({"type": "brand_new", "code": "x"})).summary_value(),
            None
        );
    }

    #[test]
    fn a_generated_image_may_be_any_non_empty_result() {
        let image = |result: Value| {
            item(&json!({"type": "image_generation_call", "result": result})).has_generated_image()
        };
        assert!(image(json!("data")));
        assert!(image(json!({"url": "x"})));
        assert!(!image(json!("")));
        assert!(!image(Value::Null));
    }
}
