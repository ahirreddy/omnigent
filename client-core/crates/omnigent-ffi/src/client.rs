//! [`ClientCore`]: the object Swift holds per server window.
//!
//! Calls that answer one question (`discover_server`, `send_message`, ...) are async methods
//! that throw [`CoreError`]. Everything that changes over time (the connection phase, the
//! session list, transcripts, decisions, notifications, background failures) arrives through
//! [`CoreListener`] as [`CoreEvent`]s, in order.

use std::collections::HashMap;
use std::fmt;
use std::sync::{Arc, Mutex};

use futures::channel::mpsc::UnboundedSender;
use futures::future::AbortHandle;
use omnigent_core as core;
use omnigent_core::SessionError;
use omnigent_core::attachments::{UploadFile, UploadState};
use omnigent_core::auth::accounts::{self, AccountLoginOptions};
use omnigent_core::auth::errors::HostedAuthError;
use omnigent_core::auth::mode::AuthenticationMode as CoreMode;
use omnigent_core::auth::oidc::{self, OidcCredentials, OidcServer, OidcSignInAttempt};
use omnigent_core::auth::pkce::PkcePair;
use omnigent_core::auth::ticket::{self, BrowserLogin, PollStatus};
use omnigent_core::auth::{SecretString, SecureStoreKey};
use omnigent_core::demo::DemoTransport;
use omnigent_core::http::HttpTransport as _;

use crate::connection::{self, HostConfig, Resolved};
use crate::databricks::DatabricksAuth;
use crate::decisions::DecisionResponse;
use crate::engine::{Bridge, Engine, Link, Listeners, Msg, SignInContext, Transports, View, lock};
use crate::errors::CoreError;
use crate::events::{
    BrowserLoginInfo, ConnectedServer, ConnectionPhase, CoreEvent, CoreListener, ErrorScope,
    OidcChallenge,
};
use crate::host::{
    Clock, EntropySource, EventStreamTransport, ForeignEntropy, ForeignHttp, ForeignStore,
    HttpTransport, Scheduler, SecureStore, WebSocketTransport,
};
use crate::runtime::{CoreTransport, Host, Sessions, post};

/// How the server signs users in (`auth.mode` in the manifest).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum AuthMode {
    /// OIDC, including the native loopback sign-in.
    Oidc,
    /// Built-in username/password accounts.
    Accounts,
    /// Identity from a trusted reverse-proxy header.
    Header,
    /// An embedding app's own provider.
    Custom,
    /// No sign-in (`none`).
    Unauthenticated,
    /// A mode newer than this client; never treated as a known one.
    Unknown {
        /// The mode string as sent.
        value: String,
    },
}

/// What the client learned about a server before signing in.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ServerDiscovery {
    /// The normalized server URL, mount path included.
    pub base_url: String,
    /// Operator display name; display only, never for trust decisions.
    pub server_name: Option<String>,
    /// Server package version; informational.
    pub server_version: Option<String>,
    /// Oldest client build the server supports; none means no floor.
    pub min_client_version: Option<String>,
    /// Absent when the server predates the manifest or its `auth` block.
    pub auth_mode: Option<AuthMode>,
    /// Private-use-scheme redirects the server accepts for native sign-in.
    pub native_redirect_uris: Vec<String>,
}

impl From<core::AuthMode> for AuthMode {
    fn from(mode: core::AuthMode) -> Self {
        match mode {
            core::AuthMode::Oidc => Self::Oidc,
            core::AuthMode::Accounts => Self::Accounts,
            core::AuthMode::Header => Self::Header,
            core::AuthMode::Custom => Self::Custom,
            core::AuthMode::None => Self::Unauthenticated,
            core::AuthMode::Unknown { value } => Self::Unknown { value },
        }
    }
}

impl From<core::ServerDiscovery> for ServerDiscovery {
    fn from(discovery: core::ServerDiscovery) -> Self {
        Self {
            base_url: discovery.base_url,
            server_name: discovery.server_name,
            server_version: discovery.server_version,
            min_client_version: discovery.min_client_version,
            auth_mode: discovery.auth_mode.map(Into::into),
            native_redirect_uris: discovery.native_redirect_uris,
        }
    }
}

/// A sent message and the composer text to show after it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MessageSent {
    /// The message was persisted or queued.
    pub queued: bool,
    /// The persisted item id; it arrives again in `session.input.consumed`.
    pub item_id: Option<String>,
    /// A native-terminal pending input id.
    pub pending_id: Option<String>,
    /// The composer text now: cleared unless the user kept typing meanwhile.
    pub draft: String,
}

/// Where one staged file's upload stands.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum UploadStatus {
    /// Staged, not uploaded.
    Staged,
    /// Uploading.
    Uploading {
        /// 0 to 1.
        progress: f64,
    },
    /// Uploaded.
    Uploaded {
        /// The session file id.
        file_id: String,
    },
    /// Failed; it may be retried.
    Failed {
        /// Why, for display.
        message: String,
    },
    /// The file may already be stored; review before retrying.
    Uncertain {
        /// Why, for display.
        message: String,
    },
}

/// One staged file.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DraftAttachment {
    /// Identifies it in this draft.
    pub id: u64,
    /// File name.
    pub filename: String,
    /// Resolved media type.
    pub media_type: String,
    /// Size in bytes.
    pub byte_count: u64,
    /// An image.
    pub is_image: bool,
    /// Upload state.
    pub status: UploadStatus,
}

/// A session's composer attachments.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AttachmentDraft {
    /// Staged files, in order.
    pub items: Vec<DraftAttachment>,
    /// Why the last selection was refused.
    pub selection_error: Option<String>,
}

impl From<core::attachments::AttachmentDraft> for AttachmentDraft {
    fn from(draft: core::attachments::AttachmentDraft) -> Self {
        Self {
            items: draft
                .items()
                .iter()
                .map(|item| DraftAttachment {
                    id: item.id().get(),
                    filename: item.file().filename().to_owned(),
                    media_type: item.file().media_type().to_owned(),
                    byte_count: u64::try_from(item.file().data().len()).unwrap_or(u64::MAX),
                    is_image: item.file().is_image(),
                    status: match item.state() {
                        UploadState::Staged => UploadStatus::Staged,
                        UploadState::Uploading { progress } => UploadStatus::Uploading {
                            progress: *progress,
                        },
                        UploadState::Uploaded(attachment) => UploadStatus::Uploaded {
                            file_id: attachment.id.clone(),
                        },
                        UploadState::Failed(error) => UploadStatus::Failed {
                            message: error.to_string(),
                        },
                        UploadState::Uncertain(error) => UploadStatus::Uncertain {
                            message: error.to_string(),
                        },
                    },
                })
                .collect(),
            selection_error: draft.selection_error().map(str::to_owned),
        }
    }
}

/// Sign-in work tied to the current connection; replaced by every connect.
#[derive(Default)]
pub(crate) struct AuthState {
    pub(crate) generation: u64,
    pub(crate) resolved: Option<Resolved>,
    pub(crate) connected_user: Option<String>,
    attempts: HashMap<u64, OidcSignInAttempt>,
    next_attempt: u64,
    pub(crate) renewal: Option<AbortHandle>,
}

pub(crate) struct Inner {
    pub(crate) host: Host,
    config: HostConfig,
    pub(crate) transport: CoreTransport,
    store: Option<ForeignStore>,
    entropy: Option<ForeignEntropy>,
    pub(crate) sessions: Arc<Sessions>,
    listeners: Arc<Listeners>,
    tx: UnboundedSender<Msg>,
    oidc: Option<OidcCredentials<CoreTransport, ForeignStore>>,
    pub(crate) databricks: Option<DatabricksAuth>,
    /// The WebSocket transport, for terminal attaches; absent in the demo.
    pub(crate) sockets: Option<Arc<dyn WebSocketTransport>>,
    demo: Option<Arc<DemoTransport>>,
    pub(crate) auth: Mutex<AuthState>,
}

/// The client core for one server connection. Safe to share across threads.
#[derive(uniffi::Object)]
pub struct ClientCore {
    pub(crate) inner: Arc<Inner>,
}

impl fmt::Debug for ClientCore {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("ClientCore")
    }
}

impl Drop for ClientCore {
    fn drop(&mut self) {
        post(&self.inner.tx, Msg::Shutdown);
    }
}

fn superseded() -> CoreError {
    CoreError::invalid_state("A newer connect or sign-out replaced this one.")
}

fn demo_only_error() -> CoreError {
    CoreError::invalid_state("Sign-in is not available in the offline demo.")
}

impl Inner {
    pub(crate) fn post(&self, message: Msg) {
        post(&self.tx, message);
    }

    pub(crate) fn store(&self) -> Result<&ForeignStore, CoreError> {
        self.store.as_ref().ok_or_else(demo_only_error)
    }

    pub(crate) fn entropy(&self) -> Result<&ForeignEntropy, CoreError> {
        self.entropy.as_ref().ok_or_else(demo_only_error)
    }

    fn oidc(&self) -> Result<&OidcCredentials<CoreTransport, ForeignStore>, CoreError> {
        self.oidc.as_ref().ok_or_else(demo_only_error)
    }

    /// Starts a new connection generation, cancelling sign-in work of the old one.
    fn begin_generation(&self) -> u64 {
        let mut auth = lock(&self.auth);
        auth.generation = auth.generation.wrapping_add(1);
        auth.attempts.clear();
        auth.connected_user = None;
        if let Some(renewal) = auth.renewal.take() {
            renewal.abort();
        }
        let generation = auth.generation;
        drop(auth);
        if let Some(databricks) = &self.databricks {
            databricks.reset_login();
        }
        generation
    }

    pub(crate) fn check_generation(&self, generation: u64) -> Result<(), CoreError> {
        if lock(&self.auth).generation == generation {
            Ok(())
        } else {
            Err(superseded())
        }
    }

    pub(crate) fn resolved(&self) -> Result<Resolved, CoreError> {
        lock(&self.auth)
            .resolved
            .clone()
            .ok_or_else(|| CoreError::invalid_state("Connect to a server before signing in."))
    }

    fn sign_in_context(&self, resolved: &Resolved) -> SignInContext {
        SignInContext {
            base_url: resolved.endpoint.base_url().to_owned(),
            server_name: resolved.discovery.server_name.clone(),
            mode: resolved.mode.clone().into(),
            methods: connection::sign_in_methods(resolved, &self.config),
        }
    }

    pub(crate) fn sign_in_required(
        &self,
        resolved: &Resolved,
        reason: Option<CoreError>,
    ) -> ConnectionPhase {
        let context = self.sign_in_context(resolved);
        let phase = ConnectionPhase::SignInRequired {
            base_url: context.base_url,
            server_name: context.server_name,
            mode: context.mode,
            methods: context.methods,
            reason,
        };
        self.post(Msg::Phase(phase.clone()));
        phase
    }

    pub(crate) fn fail(&self, server_url: &str, error: CoreError) -> CoreError {
        self.post(Msg::Phase(ConnectionPhase::Failed {
            server_url: server_url.to_owned(),
            error: error.clone(),
        }));
        error
    }

    /// Confirms identity with `bearer` and hands the connection to the engine.
    pub(crate) async fn establish(
        &self,
        generation: u64,
        resolved: &Resolved,
        bearer: Option<SecretString>,
        expected_user_id: Option<String>,
    ) -> Result<ConnectedServer, CoreError> {
        let base_url = resolved.endpoint.base_url().to_owned();
        self.post(Msg::Phase(ConnectionPhase::Connecting {
            base_url: base_url.clone(),
        }));
        let result = self
            .sessions
            .connect(resolved.endpoint.clone(), bearer.clone(), expected_user_id)
            .await;
        self.check_generation(generation)?;
        let server = match result {
            Ok(server) => server,
            Err(error) => {
                let error = CoreError::from(error);
                if error.requires_sign_in() && resolved.mode != CoreMode::LocalSingleUser {
                    self.sign_in_required(resolved, Some(error.clone()));
                    return Err(error);
                }
                return Err(self.fail(&base_url, error));
            }
        };
        let connected = ConnectedServer {
            base_url: server.base_url.clone(),
            server_name: resolved.discovery.server_name.clone(),
            account_id: server.scope.account_id(),
            user_id: server.user_id.clone(),
            mode: resolved.mode.clone().into(),
        };
        lock(&self.auth).connected_user = Some(server.user_id);
        self.post(Msg::Connected {
            link: Link {
                endpoint: resolved.endpoint.clone(),
                bearer,
            },
            server: connected.clone(),
            sign_in: self.sign_in_context(resolved),
        });
        Ok(connected)
    }

    async fn connect(
        self: &Arc<Self>,
        server_url: &str,
        expected_user_id: Option<String>,
    ) -> Result<ConnectionPhase, CoreError> {
        let generation = self.begin_generation();
        self.post(Msg::Disconnected {
            phase: ConnectionPhase::Discovering {
                server_url: server_url.to_owned(),
            },
        });
        if self.demo.is_some() {
            return self.connect_demo(generation).await;
        }
        let resolved =
            match connection::resolve(&self.transport, server_url, self.config.url_policy).await {
                Ok(resolved) => resolved,
                Err(error) => {
                    self.check_generation(generation)?;
                    return Err(self.fail(server_url, error));
                }
            };
        self.check_generation(generation)?;
        lock(&self.auth).resolved = Some(resolved.clone());
        // The server's auth mode decides, never the host: `resolve_mode` reports the local
        // runtime (`none` or `header` plus `single_user`) as `LocalSingleUser`, and an accounts or
        // OIDC server on 127.0.0.1 signs in like a hosted one.
        match &resolved.mode {
            CoreMode::LocalSingleUser => self
                .establish(generation, &resolved, None, None)
                .await
                .map(|server| ConnectionPhase::Connected { server }),
            CoreMode::Accounts => {
                let Some(user_id) = expected_user_id else {
                    return Ok(self.sign_in_required(&resolved, None));
                };
                let scope = resolved.endpoint.identity_scope(&user_id);
                let loaded =
                    accounts::load_credential(self.store()?, &scope, self.host.unix_ms()).await;
                self.check_generation(generation)?;
                match loaded {
                    Ok(Some(credential)) => self
                        .establish(generation, &resolved, Some(credential.token), Some(user_id))
                        .await
                        .map(|server| ConnectionPhase::Connected { server }),
                    Ok(None) => Ok(self.sign_in_required(&resolved, None)),
                    Err(error) => Ok(self.sign_in_required(&resolved, Some(error.into()))),
                }
            }
            CoreMode::Oidc => {
                self.connect_oidc(generation, &resolved, expected_user_id)
                    .await
            }
            CoreMode::Proxy if resolved.databricks_workspace.is_some() => {
                self.connect_databricks(generation, &resolved, expected_user_id)
                    .await
            }
            CoreMode::Proxy | CoreMode::Unsupported { .. } => Err(self.fail(
                resolved.endpoint.base_url(),
                HostedAuthError::UnsupportedAuthentication.into(),
            )),
        }
    }

    async fn connect_oidc(
        self: &Arc<Self>,
        generation: u64,
        resolved: &Resolved,
        expected_user_id: Option<String>,
    ) -> Result<ConnectionPhase, CoreError> {
        let server = OidcServer::new(resolved.endpoint.base_url()).map_err(CoreError::from)?;
        let stored = self.oidc()?.has_stored_grant(&server).await;
        self.check_generation(generation)?;
        match stored {
            Ok(true) => {}
            Ok(false) => return Ok(self.sign_in_required(resolved, None)),
            Err(error) => {
                return Ok(self.sign_in_required(resolved, Some(error.into())));
            }
        }
        let refreshed = self.oidc()?.refresh(&server, self.host.unix_ms()).await;
        self.check_generation(generation)?;
        match refreshed {
            Ok(session) => {
                let token = session.token.clone();
                let connected = self
                    .establish(generation, resolved, Some(token), expected_user_id)
                    .await?;
                self.schedule_renewal(generation, resolved, &server, &session);
                Ok(ConnectionPhase::Connected { server: connected })
            }
            Err(error) => Ok(self.sign_in_required(resolved, Some(error.into()))),
        }
    }

    async fn connect_demo(&self, generation: u64) -> Result<ConnectionPhase, CoreError> {
        let endpoint = core::demo::demo_endpoint().map_err(CoreError::from)?;
        let resolved = Resolved {
            discovery: core::ServerDiscovery {
                base_url: endpoint.base_url().to_owned(),
                server_name: Some("Offline demo".to_owned()),
                server_version: None,
                min_client_version: None,
                auth_mode: Some(core::AuthMode::None),
                native_redirect_uris: Vec::new(),
            },
            endpoint,
            mode: CoreMode::LocalSingleUser,
            manifest_auth: None,
            databricks_workspace: None,
        };
        lock(&self.auth).resolved = Some(resolved.clone());
        self.establish(generation, &resolved, None, None)
            .await
            .map(|server| ConnectionPhase::Connected { server })
    }

    /// Renews the OIDC session before it expires, then reconnects with the new token.
    fn schedule_renewal(
        self: &Arc<Self>,
        generation: u64,
        resolved: &Resolved,
        server: &OidcServer,
        session: &oidc::OidcSession,
    ) {
        let Some(delay) = session.renewal_delay_ms(self.host.unix_ms()) else {
            return;
        };
        let inner = Arc::clone(self);
        let resolved = resolved.clone();
        let server = server.clone();
        let timer = self.host.after(delay, move || {
            let host = inner.host.clone();
            host.spawn(async move { inner.renew(generation, resolved, server).await });
        });
        lock(&self.auth).renewal = Some(timer);
    }

    async fn renew(self: Arc<Self>, generation: u64, resolved: Resolved, server: OidcServer) {
        if self.check_generation(generation).is_err() {
            return;
        }
        let Ok(oidc) = self.oidc() else {
            return;
        };
        let refreshed = oidc.refresh(&server, self.host.unix_ms()).await;
        if self.check_generation(generation).is_err() {
            return;
        }
        match refreshed {
            Ok(session) => {
                if self
                    .rotate_credential(
                        generation,
                        &resolved,
                        session.token.clone(),
                        session.expires_at_ms,
                    )
                    .await
                {
                    self.schedule_renewal(generation, &resolved, &server, &session);
                }
            }
            Err(error) => {
                self.sessions.disconnect();
                self.post(Msg::Disconnected {
                    phase: ConnectionPhase::Disconnected,
                });
                self.sign_in_required(&resolved, Some(error.into()));
            }
        }
    }

    /// Puts a renewed bearer for the same identity in place without a reconnect: the REST
    /// client signs later requests with it, and the engine opens later stream and socket
    /// attempts with it (live ones keep running). When the connection already ended (a `401`
    /// raced the renewal), connects again with the new bearer instead. Returns whether the
    /// credential is in use.
    pub(crate) async fn rotate_credential(
        &self,
        generation: u64,
        resolved: &Resolved,
        bearer: SecretString,
        expires_at_ms: Option<u64>,
    ) -> bool {
        if self.check_generation(generation).is_err() {
            return false;
        }
        match self.sessions.rotate_bearer(bearer.clone()) {
            Ok(()) => {
                self.post(Msg::BearerRotated {
                    bearer,
                    expires_at_ms,
                });
                true
            }
            Err(SessionError::NotConnected) => {
                let user = lock(&self.auth).connected_user.clone();
                self.post(Msg::Disconnected {
                    phase: ConnectionPhase::Connecting {
                        base_url: resolved.endpoint.base_url().to_owned(),
                    },
                });
                match self
                    .establish(generation, resolved, Some(bearer), user)
                    .await
                {
                    Ok(_) => true,
                    Err(error) => {
                        self.post(Msg::Emit(CoreEvent::Error {
                            scope: ErrorScope::Connection,
                            error,
                        }));
                        false
                    }
                }
            }
            Err(error) => {
                self.post(Msg::Emit(CoreEvent::Error {
                    scope: ErrorScope::Connection,
                    error: error.into(),
                }));
                false
            }
        }
    }

    async fn poll_browser_login(
        self: Arc<Self>,
        generation: u64,
        resolved: Resolved,
        login: BrowserLogin,
    ) {
        loop {
            self.host.scheduler.sleep(ticket::POLL_INTERVAL_MS).await;
            if self.check_generation(generation).is_err() {
                return;
            }
            let now = self.host.unix_ms();
            if now >= login.expires_at_ms {
                self.sign_in_required(
                    &resolved,
                    Some(HostedAuthError::BrowserLoginExpired { reason: None }.into()),
                );
                return;
            }
            let status = match ticket::poll_request(&resolved.endpoint, &login, now) {
                Ok(request) => match self.transport.send(request).await {
                    Ok(response) => ticket::poll_status_from_response(&login, &response),
                    Err(error) => Err(HostedAuthError::Transport(error)),
                },
                Err(error) => Err(error),
            };
            if self.check_generation(generation).is_err() {
                return;
            }
            match status {
                Ok(PollStatus::Pending) => {}
                Ok(PollStatus::Complete(credential)) => {
                    let store = match self.store() {
                        Ok(store) => store,
                        Err(error) => {
                            self.sign_in_required(&resolved, Some(error));
                            return;
                        }
                    };
                    if let Err(error) = accounts::save_credential(
                        store,
                        &resolved.endpoint,
                        &credential,
                        self.host.unix_ms(),
                    )
                    .await
                    {
                        self.post(Msg::Emit(CoreEvent::Error {
                            scope: ErrorScope::Connection,
                            error: error.into(),
                        }));
                    }
                    let user = Some(credential.user_id.clone());
                    if let Err(error) = self
                        .establish(generation, &resolved, Some(credential.token), user)
                        .await
                    {
                        self.post(Msg::Emit(CoreEvent::Error {
                            scope: ErrorScope::Connection,
                            error,
                        }));
                    }
                    return;
                }
                Err(error) if ticket::should_keep_polling(&error) => {
                    self.post(Msg::Emit(CoreEvent::Error {
                        scope: ErrorScope::Connection,
                        error: error.into(),
                    }));
                }
                Err(error) => {
                    self.sign_in_required(&resolved, Some(error.into()));
                    return;
                }
            }
        }
    }

    fn draft_item(
        &self,
        session_id: &str,
        item_id: u64,
    ) -> Result<core::attachments::DraftItemId, CoreError> {
        self.sessions
            .attachment_draft(session_id)
            .map_err(CoreError::from)?
            .items()
            .iter()
            .map(core::attachments::DraftItem::id)
            .find(|id| id.get() == item_id)
            .ok_or_else(|| {
                CoreError::from(SessionError::Draft(
                    core::attachments::DraftError::UnknownItem,
                ))
            })
    }
}

#[uniffi::export]
impl ClientCore {
    /// A core for real servers, over the host's transports.
    ///
    /// # Errors
    ///
    /// [`CoreError::Entropy`] when the host RNG fails while seeding reconnect jitter.
    #[uniffi::constructor]
    #[allow(
        clippy::too_many_arguments,
        reason = "one argument per host trait keeps the Swift initializer explicit"
    )]
    pub fn new(
        http: Arc<dyn HttpTransport>,
        streams: Arc<dyn EventStreamTransport>,
        sockets: Arc<dyn WebSocketTransport>,
        clock: Arc<dyn Clock>,
        scheduler: Arc<dyn Scheduler>,
        secure_store: Arc<dyn SecureStore>,
        entropy: Arc<dyn EntropySource>,
        config: HostConfig,
    ) -> Result<Arc<Self>, CoreError> {
        let entropy = ForeignEntropy(entropy);
        let seed = entropy.seed()?;
        let transport = CoreTransport::Foreign(ForeignHttp(http));
        let store = ForeignStore(secure_store);
        let oidc = OidcCredentials::new(transport.clone(), store.clone());
        let databricks = config.databricks.as_ref().map(DatabricksAuth::new);
        Ok(Self::build(
            Host { clock, scheduler },
            config,
            transport,
            Transports {
                streams: Some(streams),
                sockets: Some(sockets),
                demo: None,
            },
            Some(store),
            Some(entropy),
            Some(oidc),
            databricks,
            seed,
        ))
    }

    /// A core over the offline sample server: no network, no sign-in. `connect` ignores its URL
    /// and opens the sample sessions; replies stream on the scheduler.
    ///
    /// # Errors
    ///
    /// [`CoreError::Decode`] when the bundled sample does not load.
    #[uniffi::constructor]
    pub fn new_demo(
        clock: Arc<dyn Clock>,
        scheduler: Arc<dyn Scheduler>,
    ) -> Result<Arc<Self>, CoreError> {
        let demo = Arc::new(DemoTransport::sample().map_err(|error| CoreError::Decode {
            message: format!("offline sample: {error}"),
        })?);
        demo.set_now(i64::try_from(clock.unix_time_ms() / 1_000).unwrap_or(i64::MAX));
        Ok(Self::build(
            Host { clock, scheduler },
            HostConfig {
                url_policy: connection::UrlPolicy::Development,
                oidc_redirect: connection::OidcRedirect::None,
                databricks: None,
            },
            CoreTransport::Demo(Arc::clone(&demo)),
            Transports {
                streams: None,
                sockets: None,
                demo: Some(demo),
            },
            None,
            None,
            None,
            None,
            0x5eed,
        ))
    }

    /// Registers `listener` for every later event; returns its id.
    pub fn subscribe(&self, listener: Arc<dyn CoreListener>) -> u64 {
        self.inner.listeners.add(listener)
    }

    /// Removes a listener. Returns whether it was registered.
    pub fn unsubscribe(&self, id: u64) -> bool {
        self.inner.listeners.remove(id)
    }

    /// Normalizes `server_url` and reads its `/.well-known/omnigent.json`. A 404 is not an
    /// error: it yields a discovery with no auth mode.
    ///
    /// # Errors
    ///
    /// [`CoreError::InvalidUrl`], [`CoreError::Transport`], [`CoreError::HttpStatus`],
    /// [`CoreError::Decode`].
    pub async fn discover_server(&self, server_url: String) -> Result<ServerDiscovery, CoreError> {
        connection::discover(
            &self.inner.transport,
            &server_url,
            self.inner.config.url_policy,
        )
        .await
        .map(|(_, discovery)| discovery.into())
    }

    /// Connects to `server_url`: discovery, then a saved credential if there is one (OIDC grant,
    /// or the accounts credential of `expected_user_id`), then identity confirmation. Returns
    /// `Connected`, or `SignInRequired` with the methods to offer. Progress is also reported
    /// as `ConnectionChanged` events.
    ///
    /// # Errors
    ///
    /// Discovery and connect failures (the phase becomes `Failed`), and
    /// [`CoreError::InvalidState`] when a newer connect replaced this one.
    pub async fn connect(
        &self,
        server_url: String,
        expected_user_id: Option<String>,
    ) -> Result<ConnectionPhase, CoreError> {
        self.inner.connect(&server_url, expected_user_id).await
    }

    /// Signs in with a username and password (accounts mode), saves the credential and
    /// connects.
    ///
    /// # Errors
    ///
    /// [`CoreError::Auth`] for a refused sign-in, then connect failures.
    pub async fn sign_in_with_password(
        &self,
        username: String,
        password: String,
    ) -> Result<ConnectedServer, CoreError> {
        let inner = &self.inner;
        let generation = lock(&inner.auth).generation;
        let resolved = inner.resolved()?;
        // The password goes only to a server whose auth mode is accounts.
        if resolved.mode != CoreMode::Accounts {
            return Err(HostedAuthError::UnsupportedAuthentication.into());
        }
        inner.post(Msg::Phase(ConnectionPhase::SigningIn {
            base_url: resolved.endpoint.base_url().to_owned(),
        }));
        let password = SecretString::new(password);
        let request = accounts::login_request(
            &resolved.endpoint,
            &username,
            &password,
            AccountLoginOptions {
                issue_refresh: false,
            },
        )
        .map_err(CoreError::from)?;
        let response = inner.transport.send(request).await;
        inner.check_generation(generation)?;
        let credential = response
            .map_err(HostedAuthError::from)
            .and_then(|response| {
                omnigent_core::auth::mode::check_json_response(&response, false)?;
                accounts::credential_from_login(&response.body, inner.host.unix_ms())
            });
        let credential = match credential {
            Ok(credential) => credential,
            Err(error) => {
                let error = CoreError::from(error);
                inner.sign_in_required(&resolved, Some(error.clone()));
                return Err(error);
            }
        };
        let saved = match inner.store() {
            Ok(store) => accounts::save_credential(
                store,
                &resolved.endpoint,
                &credential,
                inner.host.unix_ms(),
            )
            .await
            .map_err(CoreError::from),
            Err(error) => Err(error),
        };
        if let Err(error) = saved {
            // Leave `SigningIn` (unless a newer connect owns the phase): the sign-in screen shows
            // why the credential was not kept. The caller gets the save error either way.
            if inner.check_generation(generation).is_ok() {
                inner.sign_in_required(&resolved, Some(error.clone()));
            }
            return Err(error);
        }
        inner.check_generation(generation)?;
        let user = Some(credential.user_id.clone());
        inner
            .establish(generation, &resolved, Some(credential.token), user)
            .await
    }

    /// Starts a native OIDC sign-in redirecting to `redirect_uri` (the app's registered scheme,
    /// or the loopback URI of a listener the host just started). Present `authorize_url` and pass
    /// the callback to [`Self::complete_oidc_sign_in`].
    ///
    /// # Errors
    ///
    /// [`CoreError::Oidc`] for a redirect the server does not accept or a failed RNG.
    pub fn begin_oidc_sign_in(&self, redirect_uri: String) -> Result<OidcChallenge, CoreError> {
        let inner = &self.inner;
        let resolved = inner.resolved()?;
        let accepted = resolved
            .manifest_auth
            .as_ref()
            .is_some_and(|auth| auth.accepts_native_redirect(&redirect_uri));
        let server = OidcServer::new(resolved.endpoint.base_url()).map_err(CoreError::from)?;
        if !accepted {
            return Err(core::auth::errors::OidcError::RedirectNotAccepted {
                host: server.host().to_owned(),
            }
            .into());
        }
        let attempt = oidc::begin_sign_in(&server, &redirect_uri, inner.entropy()?)
            .map_err(CoreError::from)?;
        let challenge = OidcChallenge {
            attempt_id: 0,
            authorize_url: attempt.authorize_url().to_owned(),
            callback_scheme: attempt.redirect().scheme().to_owned(),
            redirect_uri: attempt.redirect().as_str().to_owned(),
        };
        let mut auth = lock(&inner.auth);
        auth.next_attempt = auth.next_attempt.wrapping_add(1);
        let attempt_id = auth.next_attempt;
        auth.attempts.insert(attempt_id, attempt);
        drop(auth);
        inner.post(Msg::Phase(ConnectionPhase::SigningIn {
            base_url: resolved.endpoint.base_url().to_owned(),
        }));
        Ok(OidcChallenge {
            attempt_id,
            ..challenge
        })
    }

    /// Finishes a native OIDC sign-in with the callback URL the sheet or listener received,
    /// saves the refresh grant and connects.
    ///
    /// # Errors
    ///
    /// [`CoreError::Oidc`] for an invalid callback, a refusal or a failed exchange;
    /// [`CoreError::InvalidState`] for an unknown attempt.
    pub async fn complete_oidc_sign_in(
        &self,
        attempt_id: u64,
        callback_url: String,
    ) -> Result<ConnectedServer, CoreError> {
        let inner = &self.inner;
        let (generation, attempt) = {
            let mut auth = lock(&inner.auth);
            let attempt = auth.attempts.remove(&attempt_id).ok_or_else(|| {
                CoreError::invalid_state("This sign-in is no longer in progress.")
            })?;
            (auth.generation, attempt)
        };
        let resolved = inner.resolved()?;
        let signed_in = inner
            .oidc()?
            .complete_sign_in(&attempt, &callback_url, inner.host.unix_ms())
            .await;
        inner.check_generation(generation)?;
        let signed_in = match signed_in {
            Ok(signed_in) => signed_in,
            Err(error) => {
                let error = CoreError::from(error);
                inner.sign_in_required(&resolved, Some(error.clone()));
                return Err(error);
            }
        };
        if let Some(error) = signed_in.stale_grant_error {
            inner.post(Msg::Emit(CoreEvent::Error {
                scope: ErrorScope::Connection,
                error: error.into(),
            }));
        }
        let connected = inner
            .establish(
                generation,
                &resolved,
                Some(signed_in.session.token.clone()),
                signed_in.user_id,
            )
            .await?;
        inner.schedule_renewal(generation, &resolved, attempt.server(), &signed_in.session);
        Ok(connected)
    }

    /// Abandons a native OIDC sign-in (the user closed the sheet).
    pub fn cancel_oidc_sign_in(&self, attempt_id: u64) {
        let inner = &self.inner;
        let removed = lock(&inner.auth).attempts.remove(&attempt_id).is_some();
        if let (true, Ok(resolved)) = (removed, inner.resolved()) {
            inner.sign_in_required(&resolved, None);
        }
    }

    /// Starts the OIDC browser-ticket sign-in: open `login_url`; the core polls in the background
    /// and connects once it is approved (phase `AwaitingBrowserLogin`, then `Connected`).
    ///
    /// # Errors
    ///
    /// [`CoreError::Auth`] when the server refuses to issue a ticket.
    pub async fn begin_browser_login(&self) -> Result<BrowserLoginInfo, CoreError> {
        let inner = &self.inner;
        let generation = lock(&inner.auth).generation;
        let resolved = inner.resolved()?;
        let pkce = PkcePair::generate(inner.entropy()?).map_err(CoreError::from)?;
        let request =
            ticket::ticket_request(&resolved.endpoint, &pkce.challenge).map_err(CoreError::from)?;
        let response = inner
            .transport
            .send(request)
            .await
            .map_err(CoreError::from)?;
        inner.check_generation(generation)?;
        let login = ticket::browser_login_from_response(
            &resolved.endpoint,
            &response,
            pkce.verifier,
            inner.host.unix_ms(),
        )
        .map_err(CoreError::from)?;
        let info = BrowserLoginInfo {
            login_url: login.login_url.clone(),
            user_code: login.user_code.clone(),
            expires_at_ms: login.expires_at_ms,
        };
        inner.post(Msg::Phase(ConnectionPhase::AwaitingBrowserLogin {
            base_url: resolved.endpoint.base_url().to_owned(),
            login: info.clone(),
        }));
        let poller = Arc::clone(inner);
        inner
            .host
            .spawn(poller.poll_browser_login(generation, resolved, login));
        Ok(info)
    }

    /// Signs out: forgets and revokes the OIDC grant or the accounts credential, then
    /// disconnects. Revocation failures are reported as events; the local sign-out still holds.
    ///
    /// # Errors
    ///
    /// [`CoreError::Oidc`] or [`CoreError::Auth`] when the saved credential could not be deleted.
    pub async fn sign_out(&self) -> Result<(), CoreError> {
        let inner = &self.inner;
        let resolved = inner.resolved()?;
        let user = lock(&inner.auth).connected_user.clone();
        inner.begin_generation();
        inner.post(Msg::Disconnected {
            phase: ConnectionPhase::Disconnected,
        });
        inner.sessions.disconnect();
        let result = match &resolved.mode {
            CoreMode::Oidc => {
                let server =
                    OidcServer::new(resolved.endpoint.base_url()).map_err(CoreError::from)?;
                let report = inner.oidc()?.sign_out(&server).await;
                if let Some(core::auth::errors::RevokeOutcome::Failed(cause)) = &report.revocation {
                    inner.post(Msg::Emit(CoreEvent::Error {
                        scope: ErrorScope::Connection,
                        error: CoreError::Oidc {
                            kind: crate::errors::OidcErrorKind::Network,
                            failure: crate::errors::AuthFailure::Transport,
                            message: format!("The server could not revoke the sign-in: {cause:?}"),
                        },
                    }));
                }
                if let Some(error) = report.load_error {
                    inner.post(Msg::Emit(CoreEvent::Error {
                        scope: ErrorScope::Connection,
                        error: error.into(),
                    }));
                }
                report
                    .delete_error
                    .map_or(Ok(()), |error| Err(error.into()))
            }
            CoreMode::Accounts => match user {
                Some(user) => accounts::remove_credential(
                    inner.store()?,
                    &resolved.endpoint.identity_scope(&user),
                )
                .await
                .map_err(CoreError::from),
                None => Ok(()),
            },
            CoreMode::Proxy if resolved.databricks_workspace.is_some() => {
                inner.forget_databricks_grant(&resolved).await
            }
            CoreMode::LocalSingleUser | CoreMode::Proxy | CoreMode::Unsupported { .. } => Ok(()),
        };
        inner.sign_in_required(&resolved, None);
        result
    }

    /// Ends the connection and every stream. Open sessions keep their state for the next
    /// connect.
    pub fn disconnect(&self) {
        self.inner.begin_generation();
        self.inner.post(Msg::Disconnected {
            phase: ConnectionPhase::Disconnected,
        });
        self.inner.sessions.disconnect();
    }

    /// Reloads the session list.
    pub fn refresh_sessions(&self) {
        self.inner.post(Msg::RefreshList);
    }

    /// Starts watching `session_id`: a `TranscriptReset`, then its stream and history.
    pub fn open_session(&self, session_id: String) {
        self.inner.post(Msg::Open(session_id));
    }

    /// Stops watching `session_id`.
    pub fn close_session(&self, session_id: String) {
        self.inner.post(Msg::Close(session_id));
    }

    /// The app returned to the foreground: reopen streams and reconcile.
    pub fn foreground(&self) {
        self.inner.post(Msg::Foreground);
    }

    /// The session the user is looking at, and whether its window is focused.
    pub fn set_view(&self, active_session_id: Option<String>, window_focused: bool) {
        self.inner.post(Msg::View(View {
            active_session_id,
            focused: window_focused,
        }));
    }

    /// Whether the app may show notifications.
    pub fn set_notifications_allowed(&self, allowed: bool) {
        self.inner.post(Msg::NotificationsAllowed(allowed));
    }

    /// Sends the composer text and the uploaded attachments of `session_id`. Never retried: an
    /// uncertain outcome blocks the next send until [`Self::acknowledge_uncertain_send`].
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`]; check `delivery_uncertain`.
    pub async fn send_message(
        &self,
        session_id: String,
        text: String,
    ) -> Result<MessageSent, CoreError> {
        let sent = self
            .inner
            .sessions
            .send_message(&session_id, &text)
            .await
            .map_err(CoreError::from)?;
        if self.inner.demo.is_some() {
            self.inner.post(Msg::DemoKick);
        }
        Ok(MessageSent {
            queued: sent.submission.queued,
            item_id: sent.submission.item_id,
            pending_id: sent.submission.pending_id,
            draft: sent.draft,
        })
    }

    /// Cancels the session's active turn.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`].
    pub async fn interrupt(&self, session_id: String) -> Result<(), CoreError> {
        self.inner
            .sessions
            .interrupt(&session_id)
            .await
            .map_err(CoreError::from)
    }

    /// Answers a decision card on the dedicated resolve route.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`] (kind `Decision` when the answer does not fit the card).
    pub async fn resolve_decision(
        &self,
        session_id: String,
        decision_id: String,
        response: DecisionResponse,
    ) -> Result<(), CoreError> {
        self.inner
            .sessions
            .resolve_decision(&session_id, &decision_id, &response.into())
            .await
            .map_err(CoreError::from)
    }

    /// The composer text the core tracks for `session_id`.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`] when not connected.
    pub fn composer_text(&self, session_id: String) -> Result<String, CoreError> {
        self.inner
            .sessions
            .composer_text(&session_id)
            .map_err(CoreError::from)
    }

    /// Records the composer text, so a send that completes later keeps newer text.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`] when not connected.
    pub fn update_composer(&self, session_id: String, text: String) -> Result<(), CoreError> {
        self.inner
            .sessions
            .update_composer(&session_id, &text)
            .map_err(CoreError::from)
    }

    /// Stages a file in `session_id`'s draft; returns its id.
    ///
    /// # Errors
    ///
    /// [`CoreError::Attachment`] for a file type or size the server will not take,
    /// [`CoreError::Session`] for draft limits.
    pub fn add_attachment(
        &self,
        session_id: String,
        filename: String,
        media_type: Option<String>,
        data: Vec<u8>,
    ) -> Result<u64, CoreError> {
        let file =
            UploadFile::new(&filename, media_type.as_deref(), data).map_err(CoreError::from)?;
        self.inner
            .sessions
            .add_attachment(&session_id, file)
            .map(core::attachments::DraftItemId::get)
            .map_err(CoreError::from)
    }

    /// Removes a staged file.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`].
    pub fn remove_attachment(&self, session_id: String, item_id: u64) -> Result<(), CoreError> {
        let item = self.inner.draft_item(&session_id, item_id)?;
        self.inner
            .sessions
            .remove_attachment(&session_id, item)
            .map_err(CoreError::from)
    }

    /// `session_id`'s staged files.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`] when not connected.
    pub fn attachment_draft(&self, session_id: String) -> Result<AttachmentDraft, CoreError> {
        self.inner
            .sessions
            .attachment_draft(&session_id)
            .map(Into::into)
            .map_err(CoreError::from)
    }

    /// Uploads one staged file. Never uploads a file twice.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`] (kind `Upload` or `Draft`).
    pub async fn upload_attachment(
        &self,
        session_id: String,
        item_id: u64,
    ) -> Result<(), CoreError> {
        let item = self.inner.draft_item(&session_id, item_id)?;
        let bytes = core::auth::EntropySource::random_bytes(self.inner.entropy()?, 16)
            .map_err(CoreError::from)?;
        let boundary = format!("omnigent-{}", core::auth::pkce::base64url(&bytes));
        self.inner
            .sessions
            .upload_attachment(&session_id, item, &boundary)
            .await
            .map(|_| ())
            .map_err(CoreError::from)
    }

    /// The user reviewed an uncertain send; sending is allowed again. Returns whether anything
    /// was blocked.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`] when not connected.
    pub fn acknowledge_uncertain_send(&self, session_id: String) -> Result<bool, CoreError> {
        self.inner
            .sessions
            .acknowledge_uncertain_send(&session_id)
            .map_err(CoreError::from)
    }

    /// Whether a send to `session_id` is in flight or awaiting review.
    ///
    /// # Errors
    ///
    /// [`CoreError::Session`] when not connected.
    pub fn is_send_blocked(&self, session_id: String) -> Result<bool, CoreError> {
        self.inner
            .sessions
            .is_send_blocked(&session_id)
            .map_err(CoreError::from)
    }

    /// Stops every connection and the engine. The core is unusable afterwards.
    pub fn shutdown(&self) {
        self.inner.post(Msg::Shutdown);
    }
}

impl ClientCore {
    /// The REST session client.
    pub(crate) fn sessions(&self) -> &Sessions {
        &self.inner.sessions
    }

    /// The host's wall-clock time, in ms since the Unix epoch.
    pub(crate) fn unix_ms(&self) -> u64 {
        self.inner.host.unix_ms()
    }

    /// Posts `message` to the engine.
    pub(crate) fn post(&self, message: Msg) {
        self.inner.post(message);
    }

    /// Whether this is the offline demo.
    pub(crate) fn is_demo(&self) -> bool {
        self.inner.demo.is_some()
    }

    #[allow(clippy::too_many_arguments, reason = "internal assembly of every part")]
    fn build(
        host: Host,
        config: HostConfig,
        transport: CoreTransport,
        transports: Transports,
        store: Option<ForeignStore>,
        entropy: Option<ForeignEntropy>,
        oidc: Option<OidcCredentials<CoreTransport, ForeignStore>>,
        databricks: Option<DatabricksAuth>,
        seed: u64,
    ) -> Arc<Self> {
        let sessions = Arc::new(Sessions::new(
            transport.clone(),
            core::CoreConfig {
                allows_insecure_http: config.url_policy == connection::UrlPolicy::Development,
            },
        ));
        let listeners = Arc::new(Listeners::default());
        let demo = transports.demo.clone();
        let sockets = transports.sockets.clone();
        let (engine, rx) = Engine::new(
            host.clone(),
            transports,
            Arc::clone(&sessions),
            Arc::clone(&listeners),
            seed,
        );
        let tx = engine.sender();
        sessions.subscribe(Arc::new(Bridge(tx.clone())));
        host.spawn(engine.run(rx));
        Arc::new(Self {
            inner: Arc::new(Inner {
                host,
                config,
                transport,
                store,
                entropy,
                sessions,
                listeners,
                tx,
                oidc,
                databricks,
                sockets,
                demo,
                auth: Mutex::new(AuthState::default()),
            }),
        })
    }
}

/// The secure-store key the core uses for a namespace and account, for hosts that inspect or
/// migrate Keychain items.
#[must_use]
#[uniffi::export]
pub fn secure_store_namespaces() -> Vec<String> {
    vec![
        SecureStoreKey::OIDC_NAMESPACE.to_owned(),
        SecureStoreKey::ACCOUNTS_NAMESPACE.to_owned(),
        SecureStoreKey::DATABRICKS_NAMESPACE.to_owned(),
    ]
}
