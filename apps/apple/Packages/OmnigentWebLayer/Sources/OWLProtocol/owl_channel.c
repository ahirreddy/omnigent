#include "owl_channel.h"

#include <bsm/libbsm.h>
#include <mach/mach_error.h>
#include <mach/notify.h>
#include <servers/bootstrap.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "owl_protocol.h"

enum {
  OWL_MSGH_ID = 0x004F574C,
  OWL_FLAG_OUT_OF_LINE = 1u,
};

typedef struct owl_envelope {
  uint32_t magic;
  uint16_t protocol_major;
  uint16_t kind;
  uint32_t flags;
  uint32_t inline_length;
  uint64_t request;
  uint64_t target;
} owl_envelope;

typedef struct owl_wire {
  mach_msg_header_t header;
  mach_msg_body_t body;
  mach_msg_port_descriptor_t port;
  mach_msg_ool_descriptor_t ool;
  owl_envelope envelope;
  uint8_t payload[OWL_INLINE_PAYLOAD_MAX];
} owl_wire;

typedef union owl_receive_buffer {
  mach_msg_header_t header;
  owl_wire wire;
  uint8_t bytes[sizeof(owl_wire) + MAX_TRAILER_SIZE];
} owl_receive_buffer;

_Static_assert(offsetof(owl_wire, envelope) % 8 == 0, "envelope must be 8-byte aligned");
_Static_assert(sizeof(owl_envelope) == 32, "envelope layout is part of the wire format");

struct owl_channel {
  mach_port_t receive;
  mach_port_t peer;
  pid_t expected_pid;
  dispatch_source_t source;
  void *context;
  owl_message_handler on_message;
  owl_event_handler on_event;
};

static kern_return_t owl_set_queue_limit(mach_port_t port) {
  mach_port_limits_t limits = {.mpl_qlimit = MACH_PORT_QLIMIT_LARGE};
  return mach_port_set_attributes(mach_task_self(), port, MACH_PORT_LIMITS_INFO,
                                  (mach_port_info_t)&limits, MACH_PORT_LIMITS_INFO_COUNT);
}

static kern_return_t owl_arm_dead_name(owl_channel *channel) {
  mach_port_t previous = MACH_PORT_NULL;
  kern_return_t kr = mach_port_request_notification(
      mach_task_self(), channel->peer, MACH_NOTIFY_DEAD_NAME, 0, channel->receive,
      MACH_MSG_TYPE_MAKE_SEND_ONCE, &previous);
  if (previous != MACH_PORT_NULL) {
    mach_port_deallocate(mach_task_self(), previous);
  }
  return kr;
}

static owl_channel *owl_channel_alloc(mach_port_t receive) {
  owl_channel *channel = calloc(1, sizeof(owl_channel));
  if (channel != NULL) {
    channel->receive = receive;
    channel->peer = MACH_PORT_NULL;
  }
  return channel;
}

static void owl_release_receive(mach_port_t receive) {
  if (receive != MACH_PORT_NULL) {
    mach_port_mod_refs(mach_task_self(), receive, MACH_PORT_RIGHT_RECEIVE, -1);
  }
}

kern_return_t owl_channel_create_listener(const char *service_name, owl_channel **out) {
  *out = NULL;
  mach_port_t receive = MACH_PORT_NULL;
  kern_return_t kr = bootstrap_check_in(bootstrap_port, service_name, &receive);
  if (kr != KERN_SUCCESS) {
    return kr;
  }
  kr = owl_set_queue_limit(receive);
  if (kr != KERN_SUCCESS) {
    owl_release_receive(receive);
    return kr;
  }
  owl_channel *channel = owl_channel_alloc(receive);
  if (channel == NULL) {
    owl_release_receive(receive);
    return KERN_RESOURCE_SHORTAGE;
  }
  *out = channel;
  return KERN_SUCCESS;
}

kern_return_t owl_channel_connect(const char *service_name, owl_channel **out) {
  *out = NULL;
  mach_port_t peer = MACH_PORT_NULL;
  kern_return_t kr = bootstrap_look_up(bootstrap_port, service_name, &peer);
  if (kr != KERN_SUCCESS) {
    return kr;
  }
  mach_port_t receive = MACH_PORT_NULL;
  kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &receive);
  if (kr != KERN_SUCCESS) {
    mach_port_deallocate(mach_task_self(), peer);
    return kr;
  }
  kr = owl_set_queue_limit(receive);
  owl_channel *channel = kr == KERN_SUCCESS ? owl_channel_alloc(receive) : NULL;
  if (channel == NULL) {
    owl_release_receive(receive);
    mach_port_deallocate(mach_task_self(), peer);
    return kr != KERN_SUCCESS ? kr : KERN_RESOURCE_SHORTAGE;
  }
  channel->peer = peer;
  kr = owl_arm_dead_name(channel);
  if (kr != KERN_SUCCESS) {
    owl_release_receive(receive);
    mach_port_deallocate(mach_task_self(), peer);
    free(channel);
    return kr;
  }
  *out = channel;
  return KERN_SUCCESS;
}

kern_return_t owl_channel_set_peer(owl_channel *channel, mach_port_t send_right) {
  if (channel->peer != MACH_PORT_NULL) {
    mach_port_deallocate(mach_task_self(), send_right);
    return KERN_INVALID_ARGUMENT;
  }
  channel->peer = send_right;
  return owl_arm_dead_name(channel);
}

void owl_channel_set_expected_pid(owl_channel *channel, pid_t pid) {
  channel->expected_pid = pid;
}

mach_port_t owl_channel_receive_port(const owl_channel *channel) {
  return channel->receive;
}

mach_port_t owl_message_take_port(owl_message *message) {
  mach_port_t port = message->port;
  message->port = MACH_PORT_NULL;
  return port;
}

kern_return_t owl_port_release(mach_port_t port) {
  return mach_port_deallocate(mach_task_self(), port);
}

const char *owl_error_string(kern_return_t code) {
  return mach_error_string(code);
}

static void owl_emit(owl_channel *channel, owl_channel_event event, int64_t detail) {
  if (channel->on_event != NULL) {
    channel->on_event(channel->context, event, detail);
  }
}

static pid_t owl_sender_pid(const owl_receive_buffer *buffer) {
  mach_msg_size_t offset = round_msg(buffer->header.msgh_size);
  if (offset + sizeof(mach_msg_audit_trailer_t) > sizeof(buffer->bytes)) {
    return -1;
  }
  mach_msg_audit_trailer_t trailer;
  memcpy(&trailer, buffer->bytes + offset, sizeof(trailer));
  if (trailer.msgh_trailer_size < sizeof(mach_msg_audit_trailer_t)) {
    return -1;
  }
  return audit_token_to_pid(trailer.msgh_audit);
}

static bool owl_handle_notification(owl_channel *channel, owl_receive_buffer *buffer,
                                    pid_t sender) {
  if (buffer->header.msgh_id != MACH_NOTIFY_DEAD_NAME || sender != 0) {
    return false;
  }
  mach_dead_name_notification_t notification;
  memcpy(&notification, buffer->bytes, sizeof(notification));
  if (notification.not_port == channel->peer) {
    // One reference for the dead name delivered by the notification, one for our own right.
    mach_port_deallocate(mach_task_self(), notification.not_port);
    mach_port_deallocate(mach_task_self(), channel->peer);
    channel->peer = MACH_PORT_NULL;
    owl_emit(channel, OWL_CHANNEL_EVENT_PEER_DIED, 0);
  } else {
    mach_port_deallocate(mach_task_self(), notification.not_port);
  }
  return true;
}

static bool owl_wire_is_valid(const owl_wire *wire) {
  const mach_msg_size_t base = (mach_msg_size_t)offsetof(owl_wire, payload);
  if ((wire->header.msgh_bits & MACH_MSGH_BITS_COMPLEX) == 0 ||
      wire->header.msgh_id != OWL_MSGH_ID || wire->header.msgh_size < base ||
      wire->header.msgh_remote_port != MACH_PORT_NULL || wire->body.msgh_descriptor_count != 2 ||
      wire->port.type != MACH_MSG_PORT_DESCRIPTOR || wire->ool.type != MACH_MSG_OOL_DESCRIPTOR ||
      wire->envelope.magic != OWL_ENVELOPE_MAGIC) {
    return false;
  }
  if (wire->port.name != MACH_PORT_NULL && wire->port.disposition != MACH_MSG_TYPE_PORT_SEND) {
    return false;
  }
  if ((wire->envelope.flags & OWL_FLAG_OUT_OF_LINE) != 0) {
    return wire->envelope.inline_length == 0;
  }
  return wire->ool.size == 0 && wire->envelope.inline_length <= OWL_INLINE_PAYLOAD_MAX &&
         wire->envelope.inline_length <= wire->header.msgh_size - base;
}

static void owl_dispatch(owl_channel *channel, owl_receive_buffer *buffer) {
  pid_t sender = owl_sender_pid(buffer);
  if (owl_handle_notification(channel, buffer, sender)) {
    return;
  }
  if (buffer->header.msgh_size < sizeof(mach_msg_header_t) + sizeof(mach_msg_body_t) ||
      !owl_wire_is_valid(&buffer->wire)) {
    owl_emit(channel, OWL_CHANNEL_EVENT_MALFORMED, buffer->header.msgh_size);
    mach_msg_destroy(&buffer->header);
    return;
  }
  if (channel->expected_pid != 0 && sender != channel->expected_pid) {
    owl_emit(channel, OWL_CHANNEL_EVENT_SENDER_REJECTED, sender);
    mach_msg_destroy(&buffer->header);
    return;
  }
  owl_wire *wire = &buffer->wire;
  bool out_of_line = (wire->envelope.flags & OWL_FLAG_OUT_OF_LINE) != 0;
  owl_message message = {
      .kind = wire->envelope.kind,
      .protocol_major = wire->envelope.protocol_major,
      .flags = wire->envelope.flags,
      .request = wire->envelope.request,
      .target = wire->envelope.target,
      .payload = out_of_line ? (const uint8_t *)wire->ool.address : wire->payload,
      .payload_length = out_of_line ? wire->ool.size : wire->envelope.inline_length,
      .port = wire->port.name,
      .sender_pid = sender,
  };
  channel->on_message(channel->context, &message);
  if (message.port != MACH_PORT_NULL) {
    mach_port_deallocate(mach_task_self(), message.port);
  }
  if (out_of_line && wire->ool.address != NULL && wire->ool.size > 0) {
    vm_deallocate(mach_task_self(), (vm_address_t)wire->ool.address, wire->ool.size);
  }
}

static void owl_drain(void *context) {
  owl_channel *channel = context;
  for (;;) {
    owl_receive_buffer buffer;
    const mach_msg_option_t options =
        MACH_RCV_MSG | MACH_RCV_TIMEOUT | MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) |
        MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT);
    kern_return_t kr = mach_msg(&buffer.header, options, 0, (mach_msg_size_t)sizeof(buffer.wire),
                                channel->receive, 0, MACH_PORT_NULL);
    if (kr == MACH_RCV_TIMED_OUT) {
      return;
    }
    if (kr != KERN_SUCCESS) {
      owl_emit(channel, OWL_CHANNEL_EVENT_RECEIVE_FAILED, kr);
      return;
    }
    owl_dispatch(channel, &buffer);
  }
}

static void owl_cancelled(void *context) {
  owl_channel *channel = context;
  owl_release_receive(channel->receive);
  if (channel->peer != MACH_PORT_NULL) {
    mach_port_deallocate(mach_task_self(), channel->peer);
  }
  owl_emit(channel, OWL_CHANNEL_EVENT_CANCELLED, 0);
  if (channel->source != NULL) {
    dispatch_release(channel->source);
  }
  free(channel);
}

void owl_channel_start(owl_channel *channel, dispatch_queue_t queue, void *context,
                       owl_message_handler on_message, owl_event_handler on_event) {
  channel->context = context;
  channel->on_message = on_message;
  channel->on_event = on_event;
  dispatch_source_t source =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, channel->receive, 0, queue);
  dispatch_set_context(source, channel);
  dispatch_source_set_event_handler_f(source, owl_drain);
  dispatch_source_set_cancel_handler_f(source, owl_cancelled);
  channel->source = source;
  dispatch_activate(source);
}

void owl_channel_destroy(owl_channel *channel) {
  if (channel->source != NULL) {
    dispatch_source_cancel(channel->source);
    return;
  }
  owl_release_receive(channel->receive);
  if (channel->peer != MACH_PORT_NULL) {
    mach_port_deallocate(mach_task_self(), channel->peer);
  }
  free(channel);
}

kern_return_t owl_channel_send(owl_channel *channel, uint16_t kind, uint64_t request,
                               uint64_t target, const void *payload, size_t length,
                               mach_port_t port, mach_msg_type_name_t disposition,
                               uint32_t timeout_ms) {
  if (channel->peer == MACH_PORT_NULL) {
    return MACH_SEND_INVALID_DEST;
  }
  if (length > UINT32_MAX || (length > 0 && payload == NULL)) {
    return KERN_INVALID_ARGUMENT;
  }
  owl_wire wire;
  memset(&wire, 0, offsetof(owl_wire, payload));
  const bool out_of_line = length > OWL_INLINE_PAYLOAD_MAX;
  const size_t inline_length = out_of_line ? 0 : length;
  const size_t size = (offsetof(owl_wire, payload) + inline_length + 3u) & ~(size_t)3u;
  wire.header.msgh_bits =
      MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND, 0, 0, MACH_MSGH_BITS_COMPLEX);
  wire.header.msgh_size = (mach_msg_size_t)size;
  wire.header.msgh_remote_port = channel->peer;
  wire.header.msgh_local_port = MACH_PORT_NULL;
  wire.header.msgh_id = OWL_MSGH_ID;
  wire.body.msgh_descriptor_count = 2;
  wire.port.name = port;
  wire.port.disposition = port != MACH_PORT_NULL ? disposition : MACH_MSG_TYPE_COPY_SEND;
  wire.port.type = MACH_MSG_PORT_DESCRIPTOR;
  wire.ool.address = out_of_line ? (void *)(uintptr_t)payload : NULL;
  wire.ool.size = out_of_line ? (mach_msg_size_t)length : 0;
  wire.ool.deallocate = false;
  wire.ool.copy = MACH_MSG_VIRTUAL_COPY;
  wire.ool.type = MACH_MSG_OOL_DESCRIPTOR;
  wire.envelope.magic = OWL_ENVELOPE_MAGIC;
  wire.envelope.protocol_major = OWL_PROTOCOL_MAJOR;
  wire.envelope.kind = kind;
  wire.envelope.flags = out_of_line ? OWL_FLAG_OUT_OF_LINE : 0;
  wire.envelope.inline_length = (uint32_t)inline_length;
  wire.envelope.request = request;
  wire.envelope.target = target;
  if (inline_length > 0) {
    memcpy(wire.payload, payload, inline_length);
  }
  kern_return_t kr = mach_msg(&wire.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                              wire.header.msgh_size, 0, MACH_PORT_NULL, timeout_ms,
                              MACH_PORT_NULL);
  if (kr == MACH_SEND_TIMED_OUT || kr == MACH_SEND_INTERRUPTED) {
    // The kernel pseudo-received the message back into this task; release what it carried.
    mach_msg_destroy(&wire.header);
  }
  return kr;
}
