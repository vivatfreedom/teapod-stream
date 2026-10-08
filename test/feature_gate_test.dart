import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teapodstream/core/constants/core_features.dart';
import 'package:teapodstream/core/models/heartbeat_settings.dart';
import 'package:teapodstream/ui/widgets/feature_gate.dart';

void main() {
  testWidgets('unsupported control stays visible and cannot change its value', (
    tester,
  ) async {
    var changed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeatureGate(
            features: CoreFeatures.rust,
            feature: CoreFeature.mux,
            child: SwitchListTile(
              title: const Text('Mux'),
              value: false,
              onChanged: (_) => changed = true,
            ),
          ),
        ),
      ),
    );
    expect(find.text('Mux'), findsOneWidget);
    expect(
      find.text(CoreFeatures.rust.unavailableReason(CoreFeature.mux)!),
      findsOneWidget,
    );
    await tester.tap(find.byType(Switch), warnIfMissed: false);
    expect(changed, isFalse);
  });

  testWidgets('the same control is interactive in Go', (tester) async {
    var changed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeatureGate(
            features: CoreFeatures.go,
            feature: CoreFeature.mux,
            child: SwitchListTile(
              title: const Text('Mux'),
              value: false,
              onChanged: (_) => changed = true,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(Switch));
    expect(changed, isTrue);
    expect(
      find.text(CoreFeatures.rust.unavailableReason(CoreFeature.mux)!),
      findsNothing,
    );
  });

  testWidgets('an imported unsupported setting can be explicitly reset', (
    tester,
  ) async {
    var reset = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeatureGate(
            features: CoreFeatures.rust,
            feature: CoreFeature.adBlocking,
            onReset: () => reset = true,
            child: const Text('Ad blocking: on'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Сбросить неподдерживаемое значение'));
    expect(reset, isTrue);
  });

  Widget tetheringToggle(
    CoreFeatures features, {
    required bool value,
    required ValueChanged<bool> onChanged,
  }) => MaterialApp(
    home: Scaffold(
      body: FeatureGate(
        features: features,
        feature: CoreFeature.tetheringControl,
        child: SwitchListTile(
          title: const Text('Раздача через VPN'),
          value: value,
          onChanged: onChanged,
        ),
      ),
    ),
  );

  testWidgets('Rust explains why the tethering switch does not apply', (
    tester,
  ) async {
    var changed = false;
    // No stored value changes what Rust does, so there is nothing to reset.
    await tester.pumpWidget(
      tetheringToggle(
        CoreFeatures.rust,
        value: true,
        onChanged: (_) => changed = true,
      ),
    );
    expect(find.text('Раздача через VPN'), findsOneWidget);
    expect(
      find.text(
        CoreFeatures.rust.unavailableReason(CoreFeature.tetheringControl)!,
      ),
      findsOneWidget,
    );
    await tester.tap(find.byType(Switch), warnIfMissed: false);
    expect(changed, isFalse);
    expect(find.text('Сбросить неподдерживаемое значение'), findsNothing);
  });

  testWidgets('Go keeps the tethering switch interactive', (tester) async {
    var changed = false;
    await tester.pumpWidget(
      tetheringToggle(
        CoreFeatures.go,
        value: false,
        onChanged: (_) => changed = true,
      ),
    );
    await tester.tap(find.byType(Switch));
    expect(changed, isTrue);
    expect(find.text('Сбросить неподдерживаемое значение'), findsNothing);
  });

  testWidgets('a stored PASSIVE probe is shown in Rust with a reset to SOCKS', (
    tester,
  ) async {
    var probe = HeartbeatProbe.passive;
    final feature = CoreFeatures.heartbeatProbeFeature(probe)!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeatureGate(
            features: CoreFeatures.rust,
            feature: feature,
            onReset: () => probe = HeartbeatProbe.socks,
            child: Text(probe.name.toUpperCase()),
          ),
        ),
      ),
    );
    expect(find.text('PASSIVE'), findsOneWidget);
    expect(
      find.text(CoreFeatures.rust.unavailableReason(feature)!),
      findsOneWidget,
    );
    await tester.tap(find.text('Сбросить неподдерживаемое значение'));
    expect(probe, HeartbeatProbe.socks);
  });
}
