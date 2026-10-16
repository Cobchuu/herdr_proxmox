/// Shared request and failure semantics for the Flutter and DOM project cards.
///
/// The gateway resolves one view — discovery, any operator override, the
/// disagreement between them and the host assessment — so the cards read a
/// single answer rather than joining two endpoints and risking a different
/// picture from the one provisioning acts on.
typedef ProjectAnalysisRequest =
    Future<dynamic> Function(String path, [Map<String, dynamic>? body]);

class ProjectAnalysisLoad {
  const ProjectAnalysisLoad(this.report);
  final Map<String, dynamic> report;

  /// One resolved entry per tool, in the resolver's order.
  List<Map<String, dynamic>> get requirements =>
      (report['requirements'] as List? ?? []).cast<Map<String, dynamic>>();

  /// The entry an operator override declared, if there is one.
  Map<String, dynamic>? get overridden {
    for (final entry in requirements) {
      if (entry['override'] is Map) return entry;
    }
    return null;
  }

  Map<String, dynamic>? get override {
    final entry = overridden;
    return entry == null
        ? null
        : (entry['override'] as Map).cast<String, dynamic>();
  }

  Map<String, dynamic> assessmentOf(Map<String, dynamic> requirement) =>
      (requirement['assessment'] as Map? ?? {}).cast<String, dynamic>();
}

Future<ProjectAnalysisLoad> loadProjectAnalysis(
  ProjectAnalysisRequest request,
  String path, {
  bool force = false,
}) async {
  final query = Uri(
    queryParameters: {'path': path, if (force) 'refresh': '1'},
  ).query;
  final report = Map<String, dynamic>.from(
    await request('projects/analysis?$query') as Map,
  );
  return ProjectAnalysisLoad(report);
}
