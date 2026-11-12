// C callers of the protocol's inline rules. A Swift test that calls an inline C function runs
// Swift's own copy of it, which carries no coverage counters; through these it runs as C.
#ifndef OWL_PROTOCOL_CALLERS_H
#define OWL_PROTOCOL_CALLERS_H

/// `owl_input_event_time`, compiled as C.
double owl_input_event_time_in_c(double event_time, double now, double earliest);

#endif  // OWL_PROTOCOL_CALLERS_H
