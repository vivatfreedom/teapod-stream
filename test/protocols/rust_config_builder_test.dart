import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:teapodstream/core/interfaces/vpn_engine.dart';
import 'package:teapodstream/core/models/dns_config.dart';
import 'package:teapodstream/core/models/routing_settings.dart';
import 'package:teapodstream/protocols/xray/rust_config_builder.dart';
import 'package:teapodstream/protocols/xray/vless_parser.dart';

String profile({String network = 'xhttp', bool extra = true}) {
  final key = base64Url.encode(List.filled(32, 7)).replaceAll('=', '');
  final padding = Uri.encodeComponent(
    jsonEncode({'mode': 'auto', 'xPaddingBytes': '100-1000'}),
  );
  return 'vless://11111111-2222-4333-8444-555555555555@edge.example:443'
      '?encryption=none&type=$network&security=reality&fp=firefox'
      '&sni=cover.example&host=edge.example&path=%2F&mode=auto'
      '&pbk=$key&sid=1234abcd&spx=%2Fprobe'
      '${extra ? '&extra=$padding' : ''}&x_padding_bytes=100-1000#test';
}

VpnEngineOptions options({
  RoutingSettings routing = const RoutingSettings(),
  DnsMode dnsMode = DnsMode.proxy,
  DnsServerConfig dnsServer = DnsServerConfig.cloudflare,
  bool proxyOnly = false,
  bool blockQuic = false,
  bool allowTethering = false,
}) => VpnEngineOptions(
  socksPort: 12345,
  httpPort: 0,
  socksUser: 'random-user',
  socksPassword: 'random-password',
  routing: routing,
  dnsMode: dnsMode,
  dnsServer: dnsServer,
  proxyOnly: proxyOnly,
  blockQuic: blockQuic,
  allowTethering: allowTethering,
);

Map<String, dynamic> rustDns(DnsServerConfig server, {bool fakeDns = false}) {
  final json = RustConfigBuilder.build(
    VlessParser.parseUri(profile())!,
    options(
      dnsServer: server,
      routing: fakeDns
          ? const RoutingSettings(
              direction: RoutingDirection.bypass,
              geositeEnabled: true,
              geositeCodes: ['youtube'],
            )
          : const RoutingSettings(),
    ),
  );
  return json['dns'] as Map<String, dynamic>;
}

DnsServerConfig customDns(String address, DnsType type) =>
    DnsServerConfig.fromPreset('custom', customAddress: address, customType: type);

void main() {
  test('preserves XHTTP Reality identity and padding independently', () {
    final config = VlessParser.parseUri(profile())!;
    final json = RustConfigBuilder.build(config, options());
    final stream = (json['outbounds'] as List).first['streamSettings'] as Map;
    expect(stream['network'], 'xhttp');
    expect(stream['security'], 'reality');
    expect(stream['realitySettings']['serverName'], 'cover.example');
    expect(stream['realitySettings']['fingerprint'], 'firefox');
    expect(stream['realitySettings']['spiderX'], '/probe');
    expect(stream['xhttpSettings']['host'], 'edge.example');
    expect(stream['xhttpSettings']['mode'], 'auto');
    expect(stream['xhttpSettings']['extra']['xPaddingBytes'], '100-1000');
  });

  test('routes TUN and diagnostic SOCKS through the same DNS/proxy rules', () {
    final json = RustConfigBuilder.build(
      VlessParser.parseUri(profile())!,
      options(),
    );
    final inbounds = json['inbounds'] as List;
    expect(inbounds.first['protocol'], 'tun');
    expect(inbounds.first.containsKey('port'), isFalse);
    expect(inbounds.last['listen'], '127.0.0.1');
    expect(inbounds.last['settings'], {'auth': 'noauth', 'udp': true});
    final rules = json['routing']['rules'] as List;
    expect((json['outbounds'] as List).first['tag'], 'proxy');
    expect(json['routing']['domainStrategy'], 'AsIs');
    expect(
      rules.every(
        (dynamic r) =>
            r['domain'] != null ||
            r['ip'] != null ||
            r['port'] != null ||
            r['inboundTag']?.contains('dns-module') == true,
      ),
      isTrue,
    );
    expect(
      rules.any(
        (dynamic r) =>
            r['outboundTag'] == 'dns-out' &&
            (r['inboundTag'] as List).contains('tun-in'),
      ),
      isTrue,
    );
    expect(json.containsKey('policy'), isFalse);
    expect(
      (json['outbounds'] as List).any(
        (dynamic o) => o['protocol'] == 'blackhole',
      ),
      isFalse,
    );
  });

  test('normalizes Markdown escapes and accepts standalone padding alias', () {
    final escaped = profile(extra: false)
        .replaceFirst('vless:', r'vless\:')
        .replaceFirst('@', r'\@')
        .replaceAll('_', r'\_');
    final config = VlessParser.parseUri(escaped);
    expect(config, isNotNull);
    expect(config!.xhttpExtra, {'xPaddingBytes': '100-1000'});
    expect(config.publicKey, isNot(contains(r'\')));
  });

  test('normalizes legacy splithttp without losing extra or mode', () {
    final json = RustConfigBuilder.build(
      VlessParser.parseUri(profile(network: 'splithttp'))!,
      options(),
    );
    final stream = (json['outbounds'] as List).first['streamSettings'];
    expect(stream['network'], 'xhttp');
    expect(stream['xhttpSettings']['extra']['xPaddingBytes'], '100-1000');
  });

  for (final direction in [
    RoutingDirection.bypass,
    RoutingDirection.onlySelected,
  ]) {
    test('geo rules choose the expected outbound in $direction mode', () {
      final json = RustConfigBuilder.build(
        VlessParser.parseUri(profile())!,
        options(
          routing: RoutingSettings(
            direction: direction,
            geoEnabled: true,
            geoCodes: ['RU'],
            geositeEnabled: true,
            geositeCodes: ['youtube'],
          ),
        ),
      );
      final rules = json['routing']['rules'] as List;
      final selected = direction == RoutingDirection.bypass
          ? 'direct'
          : 'proxy';
      expect(rules.singleWhere((dynamic r) => r['ip'] != null)['ip'], [
        'geoip:ru',
      ]);
      expect(
        rules.singleWhere((dynamic r) => r['ip'] != null)['outboundTag'],
        selected,
      );
      expect(
        rules.singleWhere(
          (dynamic r) => r['domain']?.contains('geosite:youtube') == true,
        )['outboundTag'],
        selected,
      );
      expect(
        (json['outbounds'] as List).first['tag'],
        direction == RoutingDirection.bypass ? 'proxy' : 'direct',
      );
      expect(json['dns']['fakeIp']['enabled'], isTrue);
      expect(json['routing']['domainStrategy'], 'IPIfNonMatch');
      expect(
        rules.every(
          (dynamic r) =>
              r['domain'] != null ||
              r['ip'] != null ||
              r['port'] != null ||
              r['inboundTag']?.contains('dns-module') == true,
        ),
        isTrue,
      );
    });
  }

  test('standalone site rules work without enabling GeoIP or GeoSite', () {
    final json = RustConfigBuilder.build(
      VlessParser.parseUri(profile())!,
      options(
        routing: const RoutingSettings(
          direction: RoutingDirection.bypass,
          sitesEnabled: true,
          sites: ['example.com'],
        ),
      ),
    );
    expect(
      (json['routing']['rules'] as List).any(
        (dynamic r) =>
            r['domain']?.contains('domain:example.com') == true &&
            r['outboundTag'] == 'direct',
      ),
      isTrue,
    );
  });

  test('the selected DNS server stays first and fallback stays disabled', () {
    for (final fakeDns in [false, true]) {
      final dns = rustDns(DnsServerConfig.cloudflare, fakeDns: fakeDns);
      expect(dns['servers'], [
        {'address': '1.1.1.1', 'port': 53},
      ]);
      expect(dns['disableFallback'], isTrue);
      expect(dns['tag'], 'dns-module');
      expect(dns.containsKey('fakeIp'), fakeDns);
    }
  });

  test('custom DoT keeps its port inside the tls:// URL read by xray-rust', () {
    final dns = rustDns(customDns('xbox-dns.ru:5853', DnsType.dot));
    final servers = dns['servers'] as List;
    // xray-rust ignores `port` next to a tls:// address.
    expect(servers.first, {'address': 'tls://xbox-dns.ru:5853'});
    expect(servers.last, {
      'address': '8.8.8.8',
      'port': 53,
      'domains': ['xbox-dns.ru'],
    });
    expect(dns['disableFallback'], isTrue);
    expect(
      (rustDns(customDns('tls://xbox-dns.ru', DnsType.dot))['servers']
              as List)
          .first,
      {'address': 'tls://xbox-dns.ru:853'},
    );
  });

  test('bracketed IPv6 DoT with a port is not given a second port', () {
    // DnsServerConfig keeps `]:853` in the address; xray-rust rejects `:853:853`.
    final servers =
        rustDns(customDns('[2606:4700:4700::1111]:853', DnsType.dot))['servers']
            as List;
    expect(servers.first, {'address': 'tls://[2606:4700:4700::1111]:853'});
    expect(
      (rustDns(customDns('[2001:db8::1]', DnsType.dot))['servers'] as List)
          .first,
      {'address': 'tls://[2001:db8::1]:853'},
    );
  });

  test('DoT preset uses its domain, port 853 and static host', () {
    final dns = rustDns(DnsServerConfig.cloudflareDoT);
    expect(dns['servers'], [
      {'address': 'tls://cloudflare-dns.com:853'},
    ]);
    expect(dns['hosts'], {'cloudflare-dns.com': '1.1.1.1'});
  });

  test('custom DoH keeps its URL port and gets a bootstrap after it', () {
    final dns = rustDns(
      customDns('https://dns.example.org:8443/dns-query', DnsType.doh),
    );
    expect(dns['servers'], [
      {'address': 'https://dns.example.org:8443/dns-query'},
      {
        'address': '8.8.8.8',
        'port': 53,
        'domains': ['dns.example.org'],
      },
    ]);
  });

  test('a bracketed IPv6 UDP server is passed as a bare literal', () {
    final dns = rustDns(customDns('[2001:db8::1]', DnsType.udp));
    expect(dns['servers'], [
      {'address': '2001:db8::1', 'port': 53},
    ]);
  });

  test('bare and bracketed-with-port IPv6 UDP servers keep the full address', () {
    expect(rustDns(customDns('2001:db8::1', DnsType.udp))['servers'], [
      {'address': '2001:db8::1', 'port': 53},
    ]);
    expect(rustDns(customDns('[2001:db8::1]:5353', DnsType.udp))['servers'], [
      {'address': '2001:db8::1', 'port': 5353},
    ]);
  });

  test('the tethering switch does not affect the Rust config', () {
    final config = VlessParser.parseUri(profile())!;
    expect(
      RustConfigBuilder.buildJson(config, options(allowTethering: true)),
      RustConfigBuilder.buildJson(config, options()),
    );
  });

  test('rejects unsupported profiles and options before starting VPN', () {
    expect(
      RustConfigBuilder.supports(
        VlessParser.parseUri(profile(network: 'quic'))!,
      ),
      isFalse,
    );
    final config = VlessParser.parseUri(profile())!;
    for (final opts in [
      options(proxyOnly: true),
      options(blockQuic: true),
      options(dnsMode: DnsMode.direct),
      options(routing: const RoutingSettings(adBlockEnabled: true)),
    ]) {
      expect(
        () => RustConfigBuilder.build(config, opts),
        throwsFormatException,
      );
    }
  });
}
