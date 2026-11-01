// OWL transport: a bidirectional channel of Mach messages between the client app and the web
// host. Each message carries an envelope (kind, request, target), a payload encoded per
// owl_protocol.h (inline up to OWL_INLINE_PAYLOAD_MAX bytes, out-of-line above), and at most one
// port right (for example an IOSurface Mach port). Every received message is checked against
// the peer's audit token. See DESIGN.md, "IPC".
#pragma once

#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

// Nullability annotations are a Clang extension; they make the Swift import precise.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-extension"

#ifdef __cplusplus
extern "C" {
#endif

#define OWL_ENVELOPE_MAGIC 0x314C574Fu
#define OWL_INLINE_PAYLOAD_MAX 4096u

typedef struct owl_channel owl_channel;

/// A received message. Valid only during the handler call.
typedef struct owl_message {
  uint16_t kind;
  uint16_t protocol_major;
  uint32_t flags;
  uint64_t request;
  uint64_t target;
  const uint8_t *_Nullable payload;
  size_t payload_length;
  /// A port right that arrived with the message, or MACH_PORT_NULL. The channel releases it
  /// after the handler returns unless the handler calls owl_message_take_port.
  mach_port_t port;
  /// Sender PID from the kernel audit trailer.
  pid_t sender_pid;
} owl_message;

/// Channel events reported besides messages.
typedef enum owl_channel_event {
  /// The peer's receive right is gone: the peer process exited or closed the channel.
  OWL_CHANNEL_EVENT_PEER_DIED = 1,
  /// mach_msg failed while receiving; `detail` is the kern_return_t.
  OWL_CHANNEL_EVENT_RECEIVE_FAILED = 2,
  /// A message came from a process other than the expected peer and was destroyed; `detail` is
  /// the sender PID.
  OWL_CHANNEL_EVENT_SENDER_REJECTED = 3,
  /// A message had a bad envelope and was destroyed; `detail` is the received size.
  OWL_CHANNEL_EVENT_MALFORMED = 4,
  /// The channel was destroyed and will call no handler again. Release the context here.
  OWL_CHANNEL_EVENT_CANCELLED = 5,
} owl_channel_event;

typedef void (*owl_message_handler)(void *_Nullable context, owl_message *_Nonnull message);
typedef void (*owl_event_handler)(void *_Nullable context, owl_channel_event event, int64_t detail);

/// Client side: allocates a receive right and checks it in with launchd under `service_name`,
/// so the spawned host can look it up.
kern_return_t owl_channel_create_listener(const char *_Nonnull service_name,
                                          owl_channel *_Nullable *_Nonnull out);

/// Host side: looks up `service_name` for the client's send right and allocates the host's own
/// receive right. Arms a dead-name notification on the client port.
kern_return_t owl_channel_connect(const char *_Nonnull service_name,
                                  owl_channel *_Nullable *_Nonnull out);

/// Client side: adopts the host's send right from Hello and arms a dead-name notification.
/// Takes ownership of `send_right`.
kern_return_t owl_channel_set_peer(owl_channel *_Nonnull channel, mach_port_t send_right);

/// Only messages from `pid` are accepted afterwards. 0 accepts any sender.
void owl_channel_set_expected_pid(owl_channel *_Nonnull channel, pid_t pid);

/// The channel's receive right, for sending it to the peer with MACH_MSG_TYPE_MAKE_SEND.
mach_port_t owl_channel_receive_port(const owl_channel *_Nonnull channel);

/// Starts delivering messages and events on `queue`.
void owl_channel_start(owl_channel *_Nonnull channel,
                       dispatch_queue_t _Nonnull queue,
                       void *_Nullable context,
                       owl_message_handler _Nonnull on_message,
                       owl_event_handler _Nonnull on_event);

/// Sends a message. `port` may be MACH_PORT_NULL; `disposition` is a MACH_MSG_TYPE_* value
/// (MOVE_SEND transfers the caller's right). Fails with MACH_SEND_TIMED_OUT when the peer's queue
/// stays full for `timeout_ms`, and with MACH_SEND_INVALID_DEST when the peer is gone.
kern_return_t owl_channel_send(owl_channel *_Nonnull channel,
                               uint16_t kind,
                               uint64_t request,
                               uint64_t target,
                               const void *_Nullable payload,
                               size_t length,
                               mach_port_t port,
                               mach_msg_type_name_t disposition,
                               uint32_t timeout_ms);

/// Takes ownership of the message's port right.
mach_port_t owl_message_take_port(owl_message *_Nonnull message);

/// Stops delivery and releases the channel's rights. The event handler then receives
/// OWL_CHANNEL_EVENT_CANCELLED on the channel's queue. Do not use the channel afterwards.
void owl_channel_destroy(owl_channel *_Nonnull channel);

/// Releases one user reference to a send right (mach_port_deallocate on the current task).
kern_return_t owl_port_release(mach_port_t port);

/// Human-readable text for a kern_return_t / mach_msg_return_t.
const char *_Nonnull owl_error_string(kern_return_t code);

#ifdef __cplusplus
}
#endif

#pragma clang diagnostic pop
