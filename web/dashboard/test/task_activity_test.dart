import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_dashboard/task_activity.dart';

void main() {
  test(
    'delivery states retain the agent and do not claim review readiness',
    () {
      final task = {
        'state': 'pr_open',
        'head_sha': 'sha',
        'auto_publish': true,
        'delivery_workflow': <String, dynamic>{
          'state': 'waiting_agent',
          'sha': 'sha',
        },
      };
      expect(taskNextStep(task), contains('task agent to inspect'));
      (task['delivery_workflow'] as Map)['state'] = 'waiting_remote';
      expect(taskNextStep(task), contains('GitHub mergeability and CI'));
      (task['delivery_workflow'] as Map)['state'] = 'complete';
      expect(taskNextStep(task), contains('checked by the task agent'));
      (task['delivery_workflow'] as Map)['state'] = 'attention';
      (task['delivery_workflow'] as Map)['error'] = 'PR permission denied';
      expect(taskNextStep(task), contains('PR permission denied'));
    },
  );

  test(
    'implementing distinguishes working from capture being switched off',
    () {
      final working = {'state': 'implementing', 'auto_validate': true};
      expect(
        taskNextStep(working, executor: 'service'),
        'Implementation in progress; awaiting a committed candidate.',
      );
      // Capture runs independently of the validation executor.
      expect(
        taskNextStep(working, executor: 'gateway'),
        'Implementation in progress; awaiting a committed candidate.',
      );
    },
  );

  test('a task with capture off never claims the agent is still working', () {
    final idle = {'state': 'implementing', 'auto_validate': false};
    final noService = taskNextStep(idle, executor: 'unavailable');
    expect(noService, contains('Automatic capture is off for this task'));
    expect(noService, contains('Changes'));
    final withService = taskNextStep(idle, executor: 'service');
    expect(withService, contains('Automatic capture is off for this task'));
    expect(withService, isNot(contains('awaiting a committed candidate')));
  });

  test(
    'capture and validation flags independently describe implementation',
    () {
      expect(
        taskNextStep({
          'state': 'implementing',
          'auto_capture': true,
          'auto_validate': false,
        }, executor: 'gateway'),
        'Implementation in progress; awaiting a committed candidate.',
      );
      expect(
        taskNextStep({
          'state': 'implementing',
          'auto_capture': false,
          'auto_validate': true,
        }, executor: 'service'),
        contains('Automatic capture is off'),
      );
    },
  );

  test('other states are unaffected by the executor', () {
    final completed = {
      'state': 'completed',
      'completion': {'outcome': 'complete'},
    };
    expect(
      taskNextStep(completed, executor: 'unavailable'),
      taskNextStep(completed, executor: 'service'),
    );
  });

  test('a build for another target never validates the current candidate', () {
    const head = 'b';
    const base = 'a';
    final task = {
      'state': 'review_ready',
      'head_sha': head,
      'builds': {
        // Keyed by the current candidate, but the record's own target is the
        // base: a stale build must not report this candidate as validated.
        head: {
          'state': 'complete',
          'target': base,
          'required_checks_verified': true,
        },
      },
    };
    final step = taskNextStep(task);
    expect(step, isNot(contains('validated')));
    expect(step, isNot(contains('ready for review')));
    // The same build keyed and targeted at the candidate does validate it.
    final exact = {
      'state': 'review_ready',
      'head_sha': head,
      'builds': {
        head: {
          'state': 'complete',
          'target': head,
          'required_checks_verified': true,
        },
      },
    };
    expect(taskNextStep(exact), contains('ready for review'));
  });
}
