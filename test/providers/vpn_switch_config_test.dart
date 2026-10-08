import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teapodstream/core/constants/app_constants.dart';
import 'package:teapodstream/core/constants/core_features.dart';
import 'package:teapodstream/core/models/heartbeat_settings.dart';
import 'package:teapodstream/core/models/vpn_config.dart';
import 'package:teapodstream/core/services/log_service.dart';
import 'package:teapodstream/core/services/settings_service.dart';
import 'package:teapodstream/providers/config_provider.dart';
import 'package:teapodstream/providers/settings_provider.dart';
import 'package:teapodstream/providers/vpn_provider.dart';

class _Settings extends SettingsNotifier {
  _Settings(this.value);
  final AppSettings value;
  @override
  Future<AppSettings> build() async => value;
}

class _Configs extends ConfigNotifier {
  _Configs(this.value);
  final ConfigState value;
  @override
  Future<ConfigState> build() async => value;
  @override
  Future<void> setActiveConfig(String? id) async {
    state = AsyncData(value.copyWith(activeConfigId: id));
  }
}

VpnConfig _vless(String id) => VpnConfig(
      id: id,
      name: id,
      protocol: VpnProtocol.vless,
      address: '$id.example',
      port: 443,
      uuid: '11111111-2222-4333-8444-555555555555',
      security: VpnSecurity.reality,
      transport: VpnTransport.xhttp,
      fingerprint: 'firefox',
      publicKey: base64Url.encode(List.filled(32, 7)).replaceAll('=', ''),
      shortId: '1234',
      sni: 'cover.example',
      encryption: 'none',
      createdAt: DateTime(2026),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AppConstants.methodChannel);
  const events = EventChannel('${AppConstants.methodChannel}/events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('switchConfig probes only candidates the selected core can run', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'ping' || 'measureOutbound' => 42,
        'getEngine' => CoreFeatures.current.isRust ? 'rust' : 'go',
        _ => null,
      };
    });
    final sink = StreamController<Object?>();
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(onListen: (_, s) {
        sink.stream.listen(s.success);
      }),
    );
    // permission_handler — best-effort запрос в connect().
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/permissions/methods'),
      (call) async => {17: 1},
    );

    final current = _vless('current');
    final vless = _vless('vless');
    final vmess = VpnConfig(
      id: 'vmess',
      name: 'vmess',
      protocol: VpnProtocol.vmess,
      address: 'vmess.example',
      port: 443,
      uuid: '11111111-2222-4333-8444-555555555555',
      security: VpnSecurity.tls,
      transport: VpnTransport.tcp,
      createdAt: DateTime(2026),
    );
    final container = ProviderContainer(overrides: [
      settingsProvider.overrideWith(() => _Settings(const AppSettings(
            heartbeat: HeartbeatSettings(
              probe: HeartbeatProbe.xrayDelay,
              failAction: HeartbeatFailAction.switchConfig,
              switchSource: SwitchSource.all,
            ),
          ))),
      configProvider.overrideWith(() => _Configs(ConfigState(
            configs: [current, vless, vmess],
            activeConfigId: current.id,
          ))),
    ]);
    addTearDown(container.dispose);
    await container.read(settingsProvider.future);
    await container.read(configProvider.future);
    container.read(vpnProvider);
    await pumpEventQueue();

    sink.add({'type': 'tunnel_dead', 'failures': 3});
    await pumpEventQueue();

    final probes = calls
        .where((c) => c.method == 'ping' || c.method == 'measureOutbound')
        .toList();
    if (CoreFeatures.current.isRust) {
      expect(probes.map((c) => c.method), ['ping']);
      expect((probes.single.arguments as Map)['address'], 'vless.example');
    } else {
      expect(probes.map((c) => c.method), ['measureOutbound', 'measureOutbound']);
    }
    final log = container.read(logServiceProvider).map((e) => e.message);
    expect(log.any((m) => m.contains('TCP-пингом')), CoreFeatures.current.isRust);
    expect(log.any((m) => m.contains('недоступна в этой сборке')),
        CoreFeatures.current.isRust);
    expect(container.read(configProvider).value!.activeConfigId,
        CoreFeatures.current.isRust ? 'vless' : anyOf('vless', 'vmess'));
  });
}
