/// Presentation labels; persisted lifecycle states remain owned by the gateway.
const taskStates = <String, String>{
  'completed': 'Done',
  'draft': 'Draft',
  'implementing': 'Implementing',
  'review_ready': 'Review ready',
  'published': 'Published',
  'pr_open': 'Pull request open',
  'merged': 'Merged',
  'closed': 'Closed',
};

/// A bound execution can still be working or have a clean commit awaiting
/// capture. Availability reports working in both cases, and the completion
/// receipt is only recorded at capture. The gateway's branch observation is
/// therefore the signal that distinguishes these two presentation states.
bool candidateWaiting(Map task) =>
    task['state'] == 'implementing' && task['awaiting_candidate'] == true;

/// Whether the gateway captures this task's committed candidate on its own.
///
/// Capture and validation are separate switches, and both are independent of
/// the build executor. A task written before that split carries only
/// `auto_validate`, where it opted into both, so the older flag still answers.
bool taskAutoCapture(Map task) =>
    (task['auto_capture'] ?? task['auto_validate']) == true;

String taskStateKey(Map task) =>
    (task['assignment'] as Map?)?['state'] == 'queued'
    ? 'queued'
    : candidateWaiting(task)
    ? 'awaiting_candidate'
    : '${task['state']}';

String taskStateLabel(String key) => switch (key) {
  'queued' => 'Queued',
  'awaiting_candidate' => 'Need candidate',
  'null' => 'State not recorded',
  _ => taskStates[key] ?? key,
};

String taskState(Map task) => taskStateLabel(taskStateKey(task));
