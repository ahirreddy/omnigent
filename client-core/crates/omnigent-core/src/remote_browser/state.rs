//! The tab state one attach knows: navigation, control, cursor, text input, viewport, settings,
//! stats and open dialogs, kept current from host messages.

use omnigent_protocol::remote_browser::{
    AttachMode, ControlState, CursorUpdate, DialogOpened, Holder, HostHello, HostMessage, NavState,
    Owner, Settings, Stats, TabClosedReason, TextInputMode, TextInputUpdate, Viewport,
};

/// What the client shows for one remote tab.
#[derive(Debug, Clone, PartialEq)]
pub struct TabState {
    /// The tab's profile, from `hello`.
    pub profile: Option<String>,
    /// The host build, from `hello`.
    pub host_version: Option<String>,
    /// The authoritative mode, from `hello`.
    pub mode: Option<AttachMode>,
    /// Optional capabilities the host announced.
    pub features: Vec<String>,
    /// Navigation.
    pub nav: Option<NavState>,
    /// Control ownership.
    pub control: Option<ControlState>,
    /// The cursor to draw locally.
    pub cursor: CursorUpdate,
    /// The focused field's keyboard mode.
    pub text_input: TextInputUpdate,
    /// The viewport.
    pub viewport: Option<Viewport>,
    /// Effective settings.
    pub settings: Option<Settings>,
    /// The latest stats, while requested.
    pub stats: Option<Stats>,
    /// Open JS dialogs, oldest first.
    pub dialogs: Vec<DialogOpened>,
    /// Set once the host said the tab ended.
    pub closed: Option<TabClosedReason>,
}

impl Default for TabState {
    fn default() -> Self {
        Self {
            profile: None,
            host_version: None,
            mode: None,
            features: Vec::new(),
            nav: None,
            control: None,
            cursor: CursorUpdate {
                cursor: "default".to_owned(),
                custom: None,
            },
            text_input: TextInputUpdate {
                mode: TextInputMode::None,
                caret_rect: None,
            },
            viewport: None,
            settings: None,
            stats: None,
            dialogs: Vec::new(),
            closed: None,
        }
    }
}

impl TabState {
    /// Applies `hello`.
    pub fn apply_hello(&mut self, hello: &HostHello) {
        self.profile = Some(hello.profile.clone());
        self.host_version = Some(hello.host_version.clone());
        self.mode = Some(hello.mode.clone());
        self.features.clone_from(&hello.features);
        self.viewport = Some(hello.viewport);
        self.control = Some(hello.control.clone());
        self.settings = Some(hello.settings.clone());
        // Dialogs are re-sent after setup on every connection.
        self.dialogs.clear();
    }

    /// Applies one host message. Returns whether anything visible changed.
    pub fn apply(&mut self, message: &HostMessage) -> bool {
        let before = self.clone();
        match message {
            HostMessage::Hello(hello) => self.apply_hello(hello),
            HostMessage::Nav(nav) => self.nav = Some(nav.clone()),
            HostMessage::Cursor(cursor) => self.cursor = cursor.clone(),
            HostMessage::TextInput(input) => self.text_input = input.clone(),
            HostMessage::Control(update) => self.control = Some(update.state.clone()),
            HostMessage::Dialog(dialog) => {
                self.dialogs.retain(|open| open.id != dialog.id);
                self.dialogs.push(dialog.clone());
            }
            HostMessage::DialogClosed { id } => self.dialogs.retain(|open| &open.id != id),
            HostMessage::Viewport(viewport) => self.viewport = Some(*viewport),
            HostMessage::Settings(settings) => self.settings = Some(settings.clone()),
            HostMessage::Stats(stats) => self.stats = Some(stats.clone()),
            HostMessage::TabClosed { reason } => self.closed = Some(reason.clone()),
            HostMessage::Pong { .. } | HostMessage::Error(_) | HostMessage::Unknown { .. } => {}
        }
        *self != before
    }

    /// Whether this connection holds the user's control.
    #[must_use]
    pub fn holds_control(&self) -> bool {
        self.control.as_ref().is_some_and(|control| {
            control.owner == Owner::User && control.holder == Some(Holder::This)
        })
    }

    /// Whether the user owns the tab but no connection holds control (the grace period after
    /// the holder left).
    #[must_use]
    pub fn in_grace_period(&self) -> bool {
        self.control
            .as_ref()
            .is_some_and(|control| control.owner == Owner::User && control.holder.is_none())
    }

    /// The CSS cursor to draw; unknown keywords draw as `default`.
    #[must_use]
    pub fn cursor_keyword(&self) -> &str {
        let cursor = self.cursor.cursor.as_str();
        if KNOWN_CURSORS.contains(&cursor) {
            cursor
        } else {
            "default"
        }
    }

    /// Forgets per-connection data before a reconnect (stats stop until asked again).
    pub const fn reset_connection(&mut self) {
        self.stats = None;
    }
}

/// A decoded custom cursor image.
#[derive(Debug, Clone, PartialEq)]
pub struct CursorImage {
    /// PNG bytes.
    pub png: Vec<u8>,
    /// Hotspot x in image px.
    pub hotspot_x: f64,
    /// Hotspot y in image px.
    pub hotspot_y: f64,
    /// Image px per CSS px.
    pub scale: f64,
}

impl TabState {
    /// The custom cursor image, when the cursor is `custom`. `Err` carries why the image could
    /// not be decoded; draw the default cursor then.
    #[must_use]
    pub fn custom_cursor(&self) -> Option<Result<CursorImage, String>> {
        use base64::Engine;
        let custom = self.cursor.custom.as_ref()?;
        Some(
            base64::engine::general_purpose::STANDARD
                .decode(&custom.png_base64)
                .map(|png| CursorImage {
                    png,
                    hotspot_x: custom.hotspot_x,
                    hotspot_y: custom.hotspot_y,
                    scale: custom.scale,
                })
                .map_err(|error| format!("the custom cursor image is not base64: {error}")),
        )
    }
}

/// The CSS cursor keywords of protocol v1.
pub const KNOWN_CURSORS: [&str; 27] = [
    "default",
    "pointer",
    "text",
    "crosshair",
    "wait",
    "progress",
    "help",
    "move",
    "not-allowed",
    "grab",
    "grabbing",
    "none",
    "ew-resize",
    "ns-resize",
    "nesw-resize",
    "nwse-resize",
    "col-resize",
    "row-resize",
    "zoom-in",
    "zoom-out",
    "copy",
    "alias",
    "cell",
    "context-menu",
    "vertical-text",
    "all-scroll",
    "custom",
];

#[cfg(test)]
mod tests {
    use super::*;
    use crate::remote_browser::test_support::message_text;

    fn host(name: &str) -> HostMessage {
        HostMessage::decode(&message_text(&format!("host_to_client/{name}"))).unwrap()
    }

    #[test]
    fn applies_every_fixture_message() {
        let mut state = TabState::default();
        assert!(state.apply(&host("hello")));
        assert_eq!(state.profile.as_deref(), Some("default"));
        assert!(!state.holds_control());
        assert!(state.apply(&host("nav")));
        assert!(!state.apply(&host("nav")), "the same nav changes nothing");
        assert!(state.apply(&host("control_user_this")));
        assert!(state.holds_control());
        assert!(state.apply(&host("control_grace")));
        assert!(state.in_grace_period());
        assert!(state.apply(&host("cursor_custom")));
        let image = state.custom_cursor().unwrap().unwrap();
        assert!(image.png.starts_with(b"\x89PNG"));
        assert!(state.apply(&host("cursor_unknown")));
        assert!(state.custom_cursor().is_none());
        assert_eq!(state.cursor_keyword(), "default");
        assert!(state.apply(&host("cursor")));
        assert_eq!(state.cursor_keyword(), "pointer");
        assert!(state.apply(&host("text_input")));
        assert_eq!(state.text_input.mode, TextInputMode::Email);
        assert!(state.apply(&host("dialog")));
        assert!(state.apply(&host("dialog_alert")));
        assert_eq!(state.dialogs.len(), 2);
        assert!(state.apply(&host("dialog_closed")));
        assert_eq!(state.dialogs[0].id, "dlg_2");
        assert!(state.apply(&host("viewport")));
        assert_eq!(state.viewport.unwrap().w, 1440);
        assert!(state.apply(&host("settings")));
        assert!(state.apply(&host("stats")));
        state.reset_connection();
        assert!(state.stats.is_none());
        assert!(!state.apply(&host("pong")));
        assert!(!state.apply(&host("unknown_type")));
        assert!(state.apply(&host("tab_closed")));
        assert_eq!(state.closed, Some(TabClosedReason::Crashed));
    }
}
