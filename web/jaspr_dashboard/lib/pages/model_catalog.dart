import '../ui.dart';

import '../services.dart';

import 'org_forms.dart';

String savedModelLabel(Map<String, dynamic> profile) {
  final model = profile['model'] as String? ?? '';
  final provider = profile['provider'] as String? ?? '';
  return model.isEmpty
      ? 'CLI default'
      : [if (provider.isNotEmpty) provider, model].join('/');
}

String savedReasoningLabel(Map<String, dynamic> profile) {
  final reasoning = profile['reasoning'] as String? ?? '';
  return reasoning.isEmpty ? 'Model default' : reasoning;
}

/// Sentinel item value that reveals the manual entry field.

const String manualEntry = 'manual';

/// One selectable model, as reported by the gateway catalog or by

/// `opencode models`. [provider] is empty for the single-provider CLIs.

class CatalogModel {
  const CatalogModel({
    required this.id,

    required this.name,

    this.provider = '',

    this.reasoning = const [],
  });

  final String id;

  final String name;

  final String provider;

  final List<String> reasoning;

  factory CatalogModel.fromJson(Map<String, dynamic> json) => CatalogModel(
    id: '${json['id'] ?? ''}',

    name: '${json['name'] ?? json['id'] ?? ''}',

    provider: '${json['provider'] ?? ''}',

    reasoning: List<String>.from(json['reasoning'] ?? []),
  );
}

class CatalogChoice {
  const CatalogChoice({required this.id, required this.label});

  final String id;

  final String label;

  factory CatalogChoice.fromJson(Map<String, dynamic> json) => CatalogChoice(
    id: '${json['id'] ?? ''}',

    label: '${json['label'] ?? json['id'] ?? ''}',
  );
}

/// Dropdown options for one runtime.

class RuntimeCatalog {
  const RuntimeCatalog({
    this.models = const [],

    this.efforts = const [],

    this.source = '',

    this.supportsVariants = false,
  });

  final List<CatalogModel> models;

  final List<CatalogChoice> efforts;

  final String source;

  final bool supportsVariants;

  List<String> get providers => {
    for (final model in models) model.provider,
  }.where((p) => p.isNotEmpty).toList()..sort();

  /// Models offered for a provider. An empty provider offers everything, so a

  /// hand-typed provider still gets suggestions.

  List<CatalogModel> forProvider(String provider) => models
      .where(
        (model) =>
            provider.isEmpty ||
            model.provider.isEmpty ||
            model.provider == provider,
      )
      .toList();

  factory RuntimeCatalog.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const RuntimeCatalog();

    return RuntimeCatalog(
      models: [
        for (final model in (json['models'] as List? ?? const []))
          if (model is Map<String, dynamic>) CatalogModel.fromJson(model),
      ],

      efforts: [
        for (final effort in (json['efforts'] as List? ?? const []))
          if (effort is Map<String, dynamic>) CatalogChoice.fromJson(effort),
      ],

      source: '${json['source'] ?? ''}',

      supportsVariants: json['supports_variants'] == true,
    );
  }
}

/// Model catalogs keyed by runtime, from `GET /api/models`.

class ModelCatalog {
  const ModelCatalog(this.runtimes);

  final Map<String, RuntimeCatalog> runtimes;

  factory ModelCatalog.fromJson(Map<String, dynamic>? json) {
    final runtimes = json?['runtimes'];

    if (runtimes is! Map) return const ModelCatalog({});

    return ModelCatalog({
      for (final entry in runtimes.entries)
        if (entry.key is String && entry.value is Map<String, dynamic>)
          entry.key as String: RuntimeCatalog.fromJson(
            entry.value as Map<String, dynamic>,
          ),
    });
  }

  RuntimeCatalog operator [](String? runtime) =>
      runtimes[runtime] ?? const RuntimeCatalog();
}

class ModelFields extends StatefulComponent {
  const ModelFields({
    super.key,
    required this.runtime,
    required this.project,
    required this.catalog,
    required this.values,
    required this.onChanged,
  });

  final String runtime, project;
  final ModelCatalog catalog;
  final Json values;
  final void Function() onChanged;

  @override
  State<ModelFields> createState() => _ModelFieldsState();
}

class _ModelFieldsState extends State<ModelFields> {
  RuntimeCatalog? discovered;
  bool busy = false;
  String? error;
  int requestId = 0;
  final manualKeys = <String>{};
  @override
  void initState() {
    super.initState();
    if (component.runtime == 'opencode' && component.project.isNotEmpty)
      discover();
  }

  RuntimeCatalog get options =>
      discovered ?? component.catalog[component.runtime];

  Future<void> discover({bool force = false}) async {
    if (busy || component.runtime != 'opencode') return;

    final epoch = dashboardConnection.generation;
    final id = ++requestId;

    setState(() {
      busy = true;
      error = null;
    });

    try {
      final result = await dashboardConnection.request('models', {
        'runtime': component.runtime,
        'project': component.project,
        'force': force,
        'provider': component.values['provider'] ?? '',
        'model': component.values['model'] ?? '',
      });

      if (!mounted ||
          epoch != dashboardConnection.generation ||
          id != requestId)
        return;

      final found = RuntimeCatalog.fromJson(
        result is Map<String, dynamic> ? result : null,
      );

      setState(() {
        if (found.models.isEmpty) {
          error = 'The CLI reported no models.';
          return;
        }
        discovered = RuntimeCatalog(
          models: found.models,
          efforts: found.efforts.isEmpty ? options.efforts : found.efforts,
          source: found.source,
          supportsVariants: found.supportsVariants,
        );
        error = result['stale'] == true
            ? 'Using cached models because refresh failed: ${result['refresh_error']}'
            : null;
      });
    } catch (e) {
      if (mounted && epoch == dashboardConnection.generation && id == requestId)
        setState(() => error = '$e');
    } finally {
      if (mounted && id == requestId) setState(() => busy = false);
    }
  }

  @override
  void didUpdateComponent(ModelFields old) {
    super.didUpdateComponent(old);
    if (old.runtime != component.runtime || old.project != component.project) {
      requestId++;
      discovered = null;
      busy = false;
      error = null;
      manualKeys.clear();
      if (component.runtime == 'opencode' && component.project.isNotEmpty)
        discover();
    }
  }

  Component picker(String key, String label, Map<String, String> choices) {
    final value = '${component.values[key] ?? ''}';

    return el('div', [
      select(
        label,
        manualKeys.contains(key) ? 'manual' : value,
        {
          '': key == 'reasoning' ? 'Model default' : 'CLI default',
          ...choices,
          if (value.isNotEmpty && value != 'manual')
            value: choices[value] ?? value,
          if (key != 'reasoning') 'manual': 'Manual entry',
        },
        (v) {
          if (v == 'manual') {
            manualKeys.add(key);
            component.values[key] = '';
            if (key == 'provider') {
              component.values['model'] = '';
              component.values['reasoning'] = '';
            }
            if (key == 'model') component.values['reasoning'] = '';
          } else {
            manualKeys.remove(key);
            component.values[key] = v;
            if (key == 'provider') {
              component.values['model'] = '';
              component.values['reasoning'] = '';
            }
            if (key == 'model') component.values['reasoning'] = '';
          }
          setState(() {});
          component.onChanged();
        },
      ),
      if (manualKeys.contains(key))
        field('$label (manual)', value, (v) {
          component.values[key] = v;
        }),
    ]);
  }

  @override
  Component build(BuildContext context) => el('section', [
    if (component.runtime == 'opencode')
      picker('provider', 'Provider', {
        for (final p in options.providers)
          p: p == 'opencode-go'
              ? 'OpenCode Go (opencode-go)'
              : p == 'opencode'
              ? 'OpenCode Zen (opencode)'
              : p,
      })
    else
      field(
        'Provider (optional)',
        '${component.values['provider'] ?? ''}',
        (v) => component.values['provider'] = v,
      ),
    if (component.runtime == 'opencode')
      prose(
        'Go subscriptions use opencode-go; opencode selects Zen. Connect the matching provider in CLI accounts. Listing a model does not prove account access.',
      ),

    picker('model', 'Model', {
      for (final m
          in (component.runtime == 'opencode' &&
                  '${component.values['provider'] ?? ''}'.isEmpty
              ? <CatalogModel>[]
              : options.forProvider(
                  component.runtime == 'opencode'
                      ? '${component.values['provider'] ?? ''}'
                      : '',
                )))
        m.id: m.name,
    }),

    picker(
      'reasoning',
      options.supportsVariants ? 'Variant / reasoning' : 'Reasoning effort',
      {
        if (component.runtime != 'opencode')
          for (final e in options.efforts) e.id: e.label,
        for (final m in options.models.where(
          (m) =>
              component.runtime == 'opencode' &&
              options.supportsVariants &&
              m.id == component.values['model'] &&
              m.provider == component.values['provider'],
        ))
          for (final r in m.reasoning) r: r,
      },
    ),

    if (component.runtime == 'opencode')
      row([
        button('Discover account models', () => discover(), disabled: busy),
        button(
          'Refresh CLI models',
          () => discover(force: true),
          disabled: busy,
        ),
      ]),

    button(
      'Use CLI defaults',
      () => setState(() {
        manualKeys.clear();
        discovered = null;
        error = null;
        for (final key in ['provider', 'model', 'reasoning'])
          component.values[key] = '';
        component.onChanged();
      }),
    ),
    if (error != null) prose(error),
    if (options.source.isNotEmpty) prose('Catalog source: ${options.source}'),
  ]);
}
