import 'package:flutter/material.dart';

/// Snapshot agents have profile IDs only after the gateway verifies ownership,
/// so both helpers key on the profile rather than a pane or alias heuristic.
bool agentRequiresAttention(
  String profileId,
  List<Map<String, dynamic>> agents,
) => agentActivity(profileId, agents) == 'attention';

/// Classify one runtime status. Shared so the sidebar and the chart cannot
/// disagree about what a status means.
String agentStatusActivity(Object? status) => switch (status) {
  'idle' || 'done' => 'idle',
  'working' || 'running' || 'busy' || 'thinking' => 'working',
  'blocked' => 'attention',
  _ => 'offline',
};

/// The single status palette. A status must not render as two different colours
/// in one view.
Color agentActivityColor(String activity, ColorScheme scheme) =>
    switch (activity) {
      'idle' => const Color(0xff56c592),
      'working' => const Color(0xff3a93ff),
      'attention' => const Color(0xffffa14d),
      _ => scheme.outline,
    };

String agentActivity(String profileId, List<Map<String, dynamic>> agents) {
  final agent = agents.where((a) => a['profile_id'] == profileId).firstOrNull;
  return agentStatusActivity(agent?['agent_status'] ?? agent?['state']);
}

class AgentStatusIndicator extends StatefulWidget {
  const AgentStatusIndicator({super.key, required this.activity});
  final String activity;

  @override
  State<AgentStatusIndicator> createState() => _AgentStatusIndicatorState();
}

class _AgentStatusIndicatorState extends State<AgentStatusIndicator>
    with SingleTickerProviderStateMixin {
  late final pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  bool get animated =>
      widget.activity == 'working' || widget.activity == 'attention';

  void updateAnimation() {
    if (animated && !MediaQuery.disableAnimationsOf(context)) {
      if (!pulse.isAnimating) pulse.repeat(reverse: true);
    } else {
      pulse.stop();
      pulse.value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    updateAnimation();
  }

  @override
  void didUpdateWidget(AgentStatusIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    updateAnimation();
  }

  @override
  void dispose() {
    pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = agentActivityColor(
      widget.activity,
      Theme.of(context).colorScheme,
    );
    final label = switch (widget.activity) {
      'attention' => 'Attention required',
      'working' => 'Working',
      'idle' => 'Idle',
      _ => 'No live session',
    };
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: SizedBox(
          width: 20,
          height: 20,
          child: AnimatedBuilder(
            animation: pulse,
            builder: (context, _) => Center(
              child: Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                  boxShadow: animated
                      ? [
                          BoxShadow(
                            color: color.withValues(
                              alpha: .15 + pulse.value * .2,
                            ),
                            spreadRadius: 1 + pulse.value * 4,
                            blurRadius: 1 + pulse.value * 3,
                          ),
                        ]
                      : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
