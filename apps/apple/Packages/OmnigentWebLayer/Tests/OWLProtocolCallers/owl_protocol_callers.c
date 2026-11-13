#include "owl_protocol_callers.h"

#include "owl_protocol.h"

double owl_input_event_time_in_c(double event_time, double now, double earliest) {
  return owl_input_event_time(event_time, now, earliest);
}

bool owl_edit_command_is_known_in_c(uint64_t command) {
  return owl_edit_command_is_known(command);
}
