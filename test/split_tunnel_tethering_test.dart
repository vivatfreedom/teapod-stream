import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teapodstream/core/constants/core_features.dart';
import 'package:teapodstream/core/services/settings_service.dart';
import 'package:teapodstream/providers/apps_provider.dart';
import 'package:teapodstream/providers/profile_provider.dart';
import 'package:teapodstream/providers/settings_provider.dart';
import 'package:teapodstream/ui/screens/split_tunnel_screen.dart';
import 'package:teapodstream/ui/theme/app_theme.dart';
import 'package:teapodstream/ui/widgets/settings_shared.dart';

class _Settings extends SettingsNotifier {
  final AppSettings initial;
  _Settings(this.initial);

  @override
  Future<AppSettings> build() async => initial;

  @override
  Future<void> save(AppSettings settings) async => state = AsyncData(settings);
}

class _Profile extends ProfileNotifier {
  @override
  Future<ProfileState> build() async =>
      const ProfileState(profiles: [], activeProfileId: 'default');
}

Future<ProviderContainer> _pumpScreen(
  WidgetTester tester,
  AppSettings settings,
) async {
  final container = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith(() => _Settings(settings)),
      profileProvider.overrideWith(_Profile.new),
      installedAppsProvider.overrideWith((ref) async => []),
    ],
  );
  addTearDown(container.dispose);
  // The test font is wider than the app's fonts, so the fixed header above
  // the app list needs more room than on a phone.
  tester.view.physicalSize = const Size(800, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark,
        home: const SplitTunnelScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

AppSettings _allExcept({required bool allowTethering}) => AppSettings(
  splitTunnelingEnabled: true,
  vpnMode: VpnMode.allExcept,
  excludedPackages: const {'org.example.excluded'},
  allowTethering: allowTethering,
);

bool _switchValue(WidgetTester tester) => tester
    .widget<SetRowToggle>(
      find.ancestor(
        of: find.text('Раздача через VPN'),
        matching: find.byType(SetRowToggle),
      ),
    )
    .value;

const _onlySelectedNotice = 'Rust-ядро не проверяет владельца потоков TUN: '
    'невыбранное приложение, привязавшее сокет к tun0, не блокируется '
    '(Go-сборка такие потоки отбрасывает).';

void main() {
  final reason = CoreFeatures.rust.unavailableReason(
    CoreFeature.tetheringControl,
  )!;

  testWidgets('tethering switch follows the selected core', (tester) async {
    final container = await _pumpScreen(
      tester,
      _allExcept(allowTethering: true),
    );

    expect(find.text('Раздача через VPN'), findsOneWidget);
    expect(find.textContaining('Защита ослаблена'), findsOneWidget);
    if (!CoreFeatures.current.isRust) {
      expect(find.text(reason), findsNothing);
      await tester.tap(find.text('Раздача через VPN'));
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).requireValue.allowTethering, isFalse);
      expect(find.textContaining('Защита ослаблена'), findsNothing);
      return;
    }

    expect(find.text(reason), findsOneWidget);
    // No stored value changes what Rust does, so there is nothing to reset.
    expect(find.text('Сбросить неподдерживаемое значение'), findsNothing);
    // The switch is inert and shows what the core does: unowned flows always pass.
    await tester.tap(find.text('Раздача через VPN'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).requireValue.allowTethering, isTrue);
    expect(_switchValue(tester), isTrue);
    expect(find.textContaining('Защита ослаблена'), findsOneWidget);
  });

  testWidgets('Rust warns even when tethering is stored as off', (tester) async {
    await _pumpScreen(tester, _allExcept(allowTethering: false));

    final rust = CoreFeatures.current.isRust;
    // Rust never blocks unowned flows, so the protected state is not shown.
    expect(_switchValue(tester), rust);
    expect(
      find.textContaining('Защита ослаблена'),
      rust ? findsOneWidget : findsNothing,
    );
    expect(find.text(reason), rust ? findsOneWidget : findsNothing);
    expect(find.text('Сбросить неподдерживаемое значение'), findsNothing);
  });

  testWidgets('Rust explains the missing owner check in ТОЛЬКО mode', (
    tester,
  ) async {
    await _pumpScreen(
      tester,
      const AppSettings(
        splitTunnelingEnabled: true,
        vpnMode: VpnMode.onlySelected,
        includedPackages: {'org.example.browser'},
      ),
    );

    expect(find.text('Раздача через VPN'), findsNothing);
    expect(
      find.text(_onlySelectedNotice),
      CoreFeatures.current.isRust ? findsOneWidget : findsNothing,
    );
  });
}
