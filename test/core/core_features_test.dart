import 'package:flutter_test/flutter_test.dart';
import 'package:teapodstream/core/constants/core_features.dart';
import 'package:teapodstream/core/models/heartbeat_settings.dart';

void main() {
  test('Go keeps all existing feature flags enabled', () {
    expect(CoreFeature.values.every(CoreFeatures.go.supports), isTrue);
  });

  test('Rust keeps routing and gates only its unsupported features', () {
    for (final feature in [
      CoreFeature.geoip,
      CoreFeature.geosite,
      CoreFeature.appRouting,
    ]) {
      expect(CoreFeatures.rust.supports(feature), isTrue);
    }
    for (final feature in [
      CoreFeature.proxyOnly,
      CoreFeature.mux,
      CoreFeature.directDns,
      CoreFeature.adBlocking,
      CoreFeature.socksAuthentication,
      CoreFeature.customMtu,
    ]) {
      expect(CoreFeatures.rust.supports(feature), isFalse);
      expect(CoreFeatures.rust.unavailableReason(feature), isNotEmpty);
    }
  });

  test('Rust gates 1.6.4+ heartbeat probes, tethering and candidate measurement', () {
    for (final feature in [
      CoreFeature.coreDelayProbe,
      CoreFeature.passiveHeartbeat,
      CoreFeature.tetheringControl,
      CoreFeature.outboundDelayProbe,
    ]) {
      expect(CoreFeatures.go.supports(feature), isTrue, reason: feature.name);
      expect(CoreFeatures.rust.supports(feature), isFalse, reason: feature.name);
      expect(CoreFeatures.rust.unavailableReason(feature), isNotEmpty);
    }
  });

  test('Go keeps every heartbeat probe exactly as stored', () {
    expect(CoreFeatures.go.heartbeatProbes, HeartbeatProbe.values);
    for (final probe in HeartbeatProbe.values) {
      expect(CoreFeatures.go.supportsHeartbeatProbe(probe), isTrue);
      expect(CoreFeatures.go.effectiveHeartbeatProbe(probe), probe);
    }
  });

  test('Rust offers only the SOCKS probe and normalizes stored probes to it', () {
    expect(CoreFeatures.rust.heartbeatProbes, [HeartbeatProbe.socks]);
    expect(CoreFeatures.heartbeatProbeFeature(HeartbeatProbe.socks), isNull);
    for (final probe in HeartbeatProbe.values) {
      expect(
        CoreFeatures.rust.effectiveHeartbeatProbe(probe),
        HeartbeatProbe.socks,
        reason: probe.name,
      );
    }
    for (final probe in [HeartbeatProbe.xrayDelay, HeartbeatProbe.passive]) {
      expect(CoreFeatures.rust.supportsHeartbeatProbe(probe), isFalse);
      expect(
        CoreFeatures.rust.unavailableReason(
          CoreFeatures.heartbeatProbeFeature(probe)!,
        ),
        isNotEmpty,
      );
    }
  });

  test('availability and its explanation agree for every feature and core', () {
    for (final features in [CoreFeatures.go, CoreFeatures.rust]) {
      for (final feature in CoreFeature.values) {
        if (features.supports(feature)) {
          expect(
            features.unavailableReason(feature),
            isNull,
            reason: feature.name,
          );
        } else {
          expect(
            features.unavailableReason(feature),
            isNotEmpty,
            reason: feature.name,
          );
        }
      }
    }
  });

  test('the build uses the requested core flag, defaulting to Go', () {
    const expected = String.fromEnvironment('TEAPOD_CORE', defaultValue: 'go');
    expect(CoreFeatures.current.isRust, expected == 'rust');
  });
}
