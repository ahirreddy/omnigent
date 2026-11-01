import OSLog

/// Logger for failures that cannot be thrown to a caller, such as a non-throwing protocol method.
let servicesLogger = Logger(subsystem: "ai.omnigent", category: "services")
