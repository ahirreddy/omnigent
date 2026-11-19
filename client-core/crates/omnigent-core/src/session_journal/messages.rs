//! What the Tasks tab asks the agent, word for word as the web sends it
//! (`web/src/lib/workflow.ts`): run, continue or retry a task, continue the plan, or stop it.

use super::view::TaskAction;

/// Tells the agent to bring back the workers a plan needs, without repeating finished work.
const RESUME_WORKFLOW_WORK: &str = "Resume or restart any previously stopped background tasks, subagents, and other Omnigent sessions needed for the remaining work. Tell each worker to resume or restart its own required tasks, agents, and sessions recursively. Check their current state first: reuse work that is still running, preserve completed results, and do not duplicate work. Retain a usable cancellation handle for every background command you start. Restore any monitoring needed to finish the workflow.";

/// The message that asks the agent to run, continue, go ahead with or retry `task_name`, then
/// go on with the rest of the plan (`taskActionMessage`); `None` for [`TaskAction::Stop`], which
/// sends [`stop_plan_message`].
#[must_use]
pub fn task_action_message(action: TaskAction, task_name: &str) -> Option<String> {
    let request = match action {
        TaskAction::Proceed => format!(
            "It's fine to continue the task \"{task_name}\". Mark it started and go ahead with it (or mark it done if its work is already done), then go on with the rest of the plan."
        ),
        TaskAction::Run | TaskAction::Continue | TaskAction::Retry => format!(
            "{} the task \"{task_name}\", then go on with the rest of the plan.",
            action.title()
        ),
        TaskAction::Stop => return None,
    };
    Some(format!("{request}\n\n{RESUME_WORKFLOW_WORK}"))
}

/// The message the plan's play control sends once the agent stopped with tasks left
/// (`continuePlanMessage`).
#[must_use]
pub fn continue_plan_message(plan_name: Option<&str>) -> String {
    let plan = plan_name.map_or_else(
        || "the plan".to_owned(),
        |name| format!("the plan \"{name}\""),
    );
    format!(
        "Continue {plan} from where you left off, and work through the tasks that are left.\n\n{RESUME_WORKFLOW_WORK}"
    )
}

/// The message that asks the main agent to stop the plan's work and say how to resume it
/// (`stopPlanMessage`).
#[must_use]
pub fn stop_plan_message(plan_name: Option<&str>) -> String {
    let plan = plan_name.map_or_else(
        || "the plan".to_owned(),
        |name| format!("the plan \"{name}\""),
    );
    format!(
        "Stop {plan} now. Stop all background tasks, subagents, and other Omnigent sessions working on this workflow run. Tell each worker to stop its own background tasks, agents, and Omnigent sessions recursively, verify their shutdown, and report back before it stops. Cancel background commands through their original task/terminal handles and wait for their exit results. A missing handle or an empty process list in another sandbox is not proof of shutdown. Cancel this run's timers and queued follow-ups that could restart the work. Keep this main session available while you coordinate and verify that the work has stopped; report anything you could not stop or verify. Preserve completed results and record the worker/session IDs and what remains so the workflow can resume. Leave unfinished steps that were started as started, not done or failed. Do not ask for confirmation or resume the workflow until I explicitly tell you to continue."
    )
}
