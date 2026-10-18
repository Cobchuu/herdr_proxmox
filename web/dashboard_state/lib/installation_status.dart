/// Operator-facing labels shared by both installation cards.
String installationStatusLabel(Object? state) => switch (state) {
  'idle' => 'Not requested',
  'queued' => 'Waiting to start',
  'running' => 'Installing',
  'complete' => 'Complete',
  'failed' => 'Failed',
  _ => 'Status unavailable',
};
