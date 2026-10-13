import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juice/juice.dart';
import 'package:herdr_dashboard/dashboard_bloc.dart';
import 'package:herdr_dashboard/toolchain_card.dart';

void main() {
  JuiceLoggerConfig.minLevel = Level.warning;
  // Flutter reuses a State when the widget tree is identical, which would let
  // one case keep the previous case's bloc and fetched status.
  var cases = 0;

  Future<DashboardBloc> pump(
    WidgetTester tester, {
    required String role,
    required Object sdk,
    void Function(http.BaseRequest request)? record,
    http.Response Function(http.Request request)? installResponse,
  }) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
    final connection = DashboardBloc(
      client: MockClient((request) async {
        record?.call(request);
        if (request.url.path == '/api/sdk/install' && installResponse != null)
          return installResponse(request);
        if (request.url.path == '/api/snapshot') {
          return http.Response('{"workspaces":[],"agents":[]}', 200);
        }
        if (request.url.path == '/api/sdk') {
          if (sdk is String) return http.Response(sdk, 503);
          return http.Response(jsonEncode(sdk), 200);
        }
        return http.Response('{}', 200);
      }),
    );
    BlocScope.register<DashboardBloc>(() => connection);
    connection.connect('token');
    // The role decides whether the install button is offered. In the app it
    // arrives with the session; here it is set directly so each case is
    // independent of that handshake.
    connection.operator.value = {'name': 'kit', 'role': role};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ToolchainCard(key: ValueKey(++cases)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return connection;
  }

  testWidgets('an administrator installs the named absent toolchain', (
    tester,
  ) async {
    var queued = false;
    final connection = await pump(
      tester,
      role: 'admin',
      sdk: {
        'state': 'idle',
        'supported': true,
        'toolchains': {
          'flutter': {
            'label': 'Flutter',
            'required': '3.44.8', 'declared_by': 'flutter.json#version',
            'installed': false,
          },
          'go': {'label': 'Go', 'required': '1.23.0', 'declared_by': 'go.json#version', 'installed': true},
        },
      },
      record: (request) {
        if (request.url.path == '/api/sdk/install') {
          queued = true;
          expect(request.method, 'POST');
          // The card names the absent toolchain rather than asking the gateway
          // to guess which one is missing.
          expect(jsonDecode((request as http.Request).body), {
            'toolchain': 'flutter',
          });
        }
      },
    );
    expect(find.text('Flutter 3.44.8'), findsOneWidget);
    expect(find.text('Go 1.23.0'), findsOneWidget);
    expect(
      find.text(
        'Absent. Required 3.44.8, declared by flutter.json#version. A root service installs it on request.',
      ),
      findsOneWidget,
    );
    // Only the absent toolchain offers an install button.
    expect(
      find.widgetWithText(FilledButton, 'Install Flutter'),
      findsOneWidget,
    );
    expect(queued, isFalse);
    await tester.ensureVisible(find.text('Install Flutter'));
    await tester.tap(find.text('Install Flutter'));
    await tester.pumpAndSettle();
    expect(queued, isTrue);
    await connection.disconnect();
    await BlocScope.reset();
  });

  testWidgets(
    'queued installation refreshes through completion without reopening settings',
    (tester) async {
      final sdk = <String, dynamic>{
        'state': 'queued',
        'toolchain': 'flutter',
        'supported': true,
        'toolchains': {
          'flutter': {
            'label': 'Flutter',
            'required': '3.44.8', 'declared_by': 'flutter.json#version',
            'installed': false,
          },
        },
      };
      final connection = await pump(tester, role: 'admin', sdk: sdk);
      expect(find.text('Installation running'), findsOneWidget);
      sdk['state'] = 'complete';
      sdk['output'] = 'Flutter initialized';
      sdk['toolchains']['flutter']['installed'] = true;
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('Installation running'), findsNothing);
      expect(find.text('Install Flutter'), findsNothing);
      expect(find.text('Installation output'), findsOneWidget);
      await tester.tap(find.text('Installation output'));
      await tester.pumpAndSettle();
      expect(find.text('Flutter initialized'), findsOneWidget);
      await connection.disconnect();
      await BlocScope.reset();
    },
  );

  testWidgets('failed POST remains visible after status refresh', (
    tester,
  ) async {
    final connection = await pump(
      tester,
      role: 'admin',
      sdk: {
        'state': 'idle',
        'supported': true,
        'toolchains': {
          'flutter': {
            'label': 'Flutter',
            'required': '3.44.8', 'declared_by': 'flutter.json#version',
            'installed': false,
          },
        },
      },
      installResponse: (_) => http.Response('{"error":"Request refused"}', 400),
    );
    await tester.tap(find.text('Install Flutter'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Request refused'), findsOneWidget);
    await tester.tap(find.byTooltip('Refresh toolchain status'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Request refused'), findsOneWidget);
    await connection.disconnect();
    await BlocScope.reset();
  });

  testWidgets('failed installation is not labelled in progress', (
    tester,
  ) async {
    final connection = await pump(
      tester,
      role: 'admin',
      sdk: {
        'state': 'failed',
        'toolchain': 'flutter',
        'supported': true,
        'error': 'Download failed',
        'toolchains': {
          'flutter': {
            'label': 'Flutter',
            'required': '3.44.8', 'declared_by': 'flutter.json#version',
            'installed': false,
          },
        },
      },
    );
    expect(find.text('Installation is in progress.'), findsNothing);
    expect(find.text('Download failed'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Install Flutter'),
          )
          .onPressed,
      isNotNull,
    );
    await connection.disconnect();
    await BlocScope.reset();
  });

  testWidgets('operators cannot request an installation', (tester) async {
    var requested = false;
    final connection = await pump(
      tester,
      role: 'operator',
      sdk: {
        'state': 'idle',
        'supported': true,
        'toolchains': {
          'flutter': {
            'label': 'Flutter',
            'required': '3.44.8', 'declared_by': 'flutter.json#version',
            'installed': false,
          },
        },
      },
      record: (request) {
        if (request.url.path == '/api/sdk/install') requested = true;
      },
    );
    expect(
      find.text('Only an administrator can request an SDK installation.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Install Flutter'),
          )
          .onPressed,
      isNull,
    );
    expect(requested, isFalse);
    await connection.disconnect();
    await BlocScope.reset();
  });

  testWidgets('a queued installation is reported as in progress', (
    tester,
  ) async {
    final connection = await pump(
      tester,
      role: 'admin',
      sdk: {
        'state': 'queued',
        'toolchain': 'flutter',
        'supported': true,
        'toolchains': {
          'flutter': {
            'label': 'Flutter',
            'required': '3.44.8', 'declared_by': 'flutter.json#version',
            'installed': false,
          },
        },
      },
    );
    expect(find.text('Installation is in progress.'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Installation running'),
          )
          .onPressed,
      isNull,
    );
    await connection.disconnect();
    await BlocScope.reset();
  });

  testWidgets('an unconfigured root service is reported, not hidden', (
    tester,
  ) async {
    final connection = await pump(
      tester,
      role: 'admin',
      sdk: {'state': 'idle', 'supported': false},
    );
    expect(
      find.text('SDK installation service is not configured'),
      findsOneWidget,
    );
    expect(find.text('Flutter 3.44.8'), findsNothing);
    await connection.disconnect();
    await BlocScope.reset();
  });

  testWidgets('a release declaring no toolchains says so', (tester) async {
    final connection = await pump(
      tester,
      role: 'admin',
      sdk: {
        'state': 'idle',
        'supported': true,
        'toolchains': <String, Object>{},
      },
    );
    expect(
      find.text('This release declares no SDK toolchains'),
      findsOneWidget,
    );
    expect(find.byType(FilledButton), findsNothing);
    await connection.disconnect();
    await BlocScope.reset();
  });

  testWidgets(
    'a malformed catalog is distinguished from an empty release catalog',
    (tester) async {
      final connection = await pump(
        tester,
        role: 'admin',
        sdk: {
          'state': 'idle',
          'supported': true,
          'toolchains': <String, Object>{},
          'catalog_error':
              'Toolchain catalog is malformed; inspect the deployed release.',
        },
      );
      expect(find.text('Toolchain catalog unavailable'), findsOneWidget);
      expect(
        find.text('This release declares no SDK toolchains'),
        findsNothing,
      );
      expect(find.byType(FilledButton), findsNothing);
      await connection.disconnect();
      await BlocScope.reset();
    },
  );

  testWidgets('an unreadable status is reported without breaking the page', (
    tester,
  ) async {
    final connection = await pump(
      tester,
      role: 'admin',
      sdk: '{"error":"Service unavailable"}',
    );
    expect(find.text('Toolchain status unavailable'), findsOneWidget);
    // The reason is stated in the tile and again as the card's error, so the
    // operator sees it either way.
    expect(find.textContaining('Service unavailable'), findsNWidgets(2));
    expect(find.widgetWithText(FilledButton, 'Install Flutter'), findsNothing);
    await connection.disconnect();
    await BlocScope.reset();
  });
}
