import '../../core/constants/core_features.dart';
import 'dart:convert';

import '../../core/interfaces/vpn_engine.dart';
import '../../core/models/dns_config.dart';
import '../../core/models/routing_settings.dart';
import '../../core/models/vpn_config.dart';
import 'xray_config_builder.dart';

/// Supported VLESS carrier/security combinations and Hysteria2 integrated with
/// Android TUN.
///
/// TLS certificate pins win over `allowInsecure`: a profile with both is built
/// with `allowInsecure: false` and `pinnedPeerCertSha256`, so the server must
/// present exactly the pinned certificate — stricter than the request, and the
/// usual intent of such links (a self-signed server identified by its pin).
/// xray-rust, like current Xray-core, has no unverified mode, so
/// `allowInsecure` without a pin is rejected.
class RustConfigBuilder {
  static const visionFlows = {'xtls-rprx-vision', 'xtls-rprx-vision-udp443'};
  static const _transports = {
    VpnTransport.tcp,
    VpnTransport.ws,
    VpnTransport.httpupgrade,
    VpnTransport.grpc,
    VpnTransport.xhttp,
    VpnTransport.splithttp,
  };
  static const _urlTransports = {
    'tcp',
    'raw',
    'ws',
    'websocket',
    'httpupgrade',
    'grpc',
    'xhttp',
    'splithttp',
  };

  static bool supports(VpnConfig config) => unsupportedReason(config) == null;

  static String? unsupportedReason(VpnConfig config) {
    if (config.rawXrayConfig != null) {
      return 'Импорт полного JSON в Rust-сборке пока недоступен.';
    }
    if (config.protocol == VpnProtocol.hysteria2) {
      return _hysteria2UnsupportedReason(config);
    }
    if (config.protocol != VpnProtocol.vless) {
      return 'Rust-сборка поддерживает протоколы VLESS и Hysteria2.';
    }
    if (config.encryption != null && config.encryption != 'none') {
      return 'Rust-сборка пока принимает VLESS с encryption=none.';
    }
    final declaredTransport = Uri.tryParse(
      config.rawUri ?? '',
    )?.queryParameters['type'];
    if (!_transports.contains(config.transport) ||
        (declaredTransport != null &&
            !_urlTransports.contains(declaredTransport.toLowerCase()))) {
      return 'Транспорт не поддерживается. Доступны TCP/RAW, WebSocket, HTTPUpgrade, gRPC и xHTTP.';
    }
    if (config.security != VpnSecurity.tls &&
        config.security != VpnSecurity.reality) {
      return 'Для VLESS в Rust-сборке выбери TLS или Reality.';
    }
    if (config.security == VpnSecurity.reality &&
        (config.transport == VpnTransport.ws ||
            config.transport == VpnTransport.httpupgrade)) {
      return 'Reality поддерживается с TCP/RAW, gRPC и xHTTP. Для WebSocket/HTTPUpgrade нужен TLS.';
    }
    final flow = config.flow ?? '';
    if (flow.isNotEmpty && !visionFlows.contains(flow)) {
      return 'Неизвестный VLESS flow.';
    }
    if (flow.isNotEmpty && config.transport != VpnTransport.tcp) {
      return 'Vision с encryption=none поддерживается только поверх TCP/RAW с TLS или Reality.';
    }
    if (flow.isNotEmpty &&
        config.security == VpnSecurity.tls &&
        !CoreFeatures.rust.supports(CoreFeature.visionWithTls)) {
      return CoreFeatures.rust.unavailableReason(CoreFeature.visionWithTls);
    }
    if (config.security == VpnSecurity.tls && _insecureWithoutPin(config)) {
      return _insecureReason;
    }
    if (config.ech?.isNotEmpty ?? false) {
      return 'ECH пока недоступен в Rust-сборке.';
    }
    return null;
  }

  /// xray-rust 0.7.0 caps a config at 250,000 domain matchers
  /// (MAX_CONFIG_DOMAIN_MATCHERS), shared by routing and DNS-outbound rules, and
  /// expands each geosite entry into one matcher. Ad blocking alone takes about
  /// 187k (category-ads-all 186,402 + win-spy 327 in the bundled Loyalsoldier
  /// 202609082347), so a GeoSite rule with one of these (cn 111,168,
  /// china-list 110,433) cannot be parsed and the VPN would not start.
  static const _largeGeositeCodes = {'cn', 'china-list', 'category-ads-all'};

  static const _insecureReason =
      'Rust не поддерживает allowInsecure без pinSHA256. Используй действительный TLS-сертификат или укажи pinSHA256 сертификата сервера.';

  static bool _hasPin(VpnConfig config) =>
      config.pinSHA256?.trim().isNotEmpty ?? false;

  static bool _insecureWithoutPin(VpnConfig config) =>
      config.allowInsecure && !_hasPin(config);

  /// xray-rust 0.7.0: Hysteria2 over stock QUIC TLS (h3), one server port,
  /// default BBR. Salamander, hopping, Brutal/QUIC overrides and sockopt
  /// (dialerProxy/noise) are rejected by the core's config parser.
  static String? _hysteria2UnsupportedReason(VpnConfig config) {
    if (config.obfsPassword?.isNotEmpty ?? false) {
      return 'Обфускация Salamander (obfs) для Hysteria2 пока недоступна в Rust-сборке.';
    }
    if (config.hopPorts?.isNotEmpty ?? false) {
      return 'Смена портов (port hopping, ${config.hopPorts}) для Hysteria2 пока недоступна в Rust-сборке. Укажи один порт сервера.';
    }
    if (config.finalmask != null) {
      return 'finalmask для Hysteria2 недоступен в Rust-сборке.';
    }
    final auth = config.password ?? '';
    if (auth.isEmpty ||
        utf8.encode(auth).length > 4096 ||
        auth.codeUnits.any((c) => c < 0x20 || c == 0x7f)) {
      return 'Пароль Hysteria2 должен быть непустым, не длиннее 4096 байт и без управляющих символов.';
    }
    if (_insecureWithoutPin(config)) return _insecureReason;
    if (config.ech?.isNotEmpty ?? false) {
      return 'ECH пока недоступен в Rust-сборке.';
    }
    return null;
  }

  static Map<String, dynamic> build(
    VpnConfig config,
    VpnEngineOptions options,
  ) {
    final reason = unsupportedReason(config);
    if (reason != null) throw FormatException(reason);
    if ((!CoreFeatures.rust.supports(CoreFeature.proxyOnly) &&
            options.proxyOnly) ||
        options.httpPort != 0) {
      throw const FormatException(
        'В Rust-пробнике доступен только режим VPN (TUN).',
      );
    }
    // Go не применяет Mux и фрагментацию к Hysteria2 (QUIC сам мультиплексирует
    // потоки, TCP-фрагментов нет), значит и здесь они не мешают. Noise Go
    // применяет к UDP-плечу через dialerProxy — xray-rust его отвергает.
    final hysteria2 = config.protocol == VpnProtocol.hysteria2;
    if ((!CoreFeatures.rust.supports(CoreFeature.mux) &&
            options.mux.enabled &&
            !hysteria2) ||
        (!CoreFeatures.rust.supports(CoreFeature.fragmentation) &&
            options.fragment.enabled &&
            !hysteria2) ||
        (!CoreFeatures.rust.supports(CoreFeature.noise) &&
            options.noise.enabled) ||
        config.finalmask != null) {
      throw const FormatException(
        'Отключи Mux, фрагментацию, noise и finalmask для Rust-пробника.',
      );
    }
    if (options.routing.isActive &&
        !options.sniffingEnabled &&
        (options.routing.geositeEnabled ||
            options.routing.domainEnabled ||
            options.routing.sitesEnabled ||
            options.routing.ruServicesEnabled)) {
      throw const FormatException(
        'Включи определение доменов для GeoSite и доменных правил.',
      );
    }
    if (options.routing.adBlockEnabled &&
        options.routing.isActive &&
        options.routing.geositeEnabled &&
        options.routing.geositeCodes.any(
          (c) => _largeGeositeCodes.contains(c.trim().toLowerCase()),
        )) {
      throw const FormatException(
        'Блокировка рекламы (~187 тыс. доменов) вместе с большой категорией GeoSite '
        '(cn, china-list, category-ads-all) превышает лимит Rust-ядра в 250 тыс. '
        'доменных правил. Отключи одно из двух.',
      );
    }
    if ((!CoreFeatures.rust.supports(CoreFeature.quicBlocking) &&
            options.blockQuic) ||
        (!CoreFeatures.rust.supports(CoreFeature.udpToggle) &&
            !options.enableUdp) ||
        (!CoreFeatures.rust.supports(CoreFeature.customMtu) &&
            options.mtu != 1500)) {
      throw const FormatException(
        'Для Rust-пробника нужны UDP, MTU 1500 и выключенная блокировка QUIC.',
      );
    }

    // Reuse the existing profile and domain-routing translation, then replace
    // the Go-specific inbound and policy. Native TUN traffic never uses SOCKS.
    final result = XrayConfigBuilder.build(config, options);
    result.remove('policy');
    if (options.dnsMode == DnsMode.direct) _routeDnsDirect(result, options);
    // Resolve for IP rules only. Domain-only routing can pass the name to
    // the server (VLESS or Hysteria2 both carry domain destinations) without
    // an extra client-side DNS round trip for every new host.
    result['routing']['domainStrategy'] =
        options.routing.isActive &&
            (options.routing.geoEnabled || options.routing.bypassLocal)
        ? 'IPIfNonMatch'
        : 'AsIs';
    // Rust 0.6 restores domain identity from FakeDNS before TUN routing.
    // Its TUN TCP sniffer alone does not classify ordinary real-IP targets.
    if (options.routing.isActive &&
        (options.routing.geositeEnabled ||
            options.routing.domainEnabled ||
            options.routing.sitesEnabled ||
            options.routing.ruServicesEnabled)) {
      (result['dns'] as Map<String, dynamic>)['fakeIp'] = {
        'enabled': true,
        'ipv4Pool': '198.18.0.0/15',
        'poolSize': 4096,
        'ttl': 300,
      };
    }
    _adaptDnsServers(result['dns'] as Map<String, dynamic>);

    final inbounds = result['inbounds'] as List<dynamic>;
    final socks = inbounds.single as Map<String, dynamic>;
    socks['listen'] = '127.0.0.1';
    socks['settings'] = {'auth': 'noauth', 'udp': true};
    inbounds.insert(0, {
      'tag': 'tun-in',
      'protocol': 'tun',
      'sniffing': Map<String, dynamic>.from(socks['sniffing'] as Map),
    });
    // Loopback SOCKS is retained for the app's IP check and heartbeat only.
    final outbounds = result['outbounds'] as List<dynamic>;
    outbounds.removeWhere((dynamic out) => out['protocol'] == 'blackhole');
    if (options.routing.adBlockEnabled) _blockAdsInDnsOutbound(result);
    final rules = (result['routing'] as Map)['rules'] as List<dynamic>;
    for (final dynamic rule in rules) {
      final tags = rule['inboundTag'];
      if (tags is List && tags.contains('socks-in')) {
        rule['inboundTag'] = ['tun-in', 'socks-in'];
      }
    }
    // A catch-all rule matches before IPIfNonMatch can resolve a restored
    // domain. Use the core's default outbound instead, leaving the second
    // routing pass available for GeoIP when GeoSite did not match.
    rules.removeLast();
    final stream = outbounds.first['streamSettings'] as Map<String, dynamic>;
    if (config.transport == VpnTransport.xhttp ||
        config.transport == VpnTransport.splithttp) {
      stream['network'] = 'xhttp';
      stream.remove('splithttpSettings');
      stream['xhttpSettings'] = {
        'host': config.wsHost ?? '',
        'path': config.wsPath ?? '/',
        'mode': config.xhttpMode ?? 'auto',
        if (config.xhttpExtra != null) 'extra': config.xhttpExtra,
      };
    }
    // pinnedPeerCertSha256 и allowInsecure: false при пине уже выставил
    // XrayConfigBuilder — тот же ключ читают оба ядра.
    final tls = stream['tlsSettings'] as Map<String, dynamic>?;
    if (hysteria2 && tls != null) {
      // QUIC TLS не маскируется под браузер, ALPN Hysteria2 — только h3,
      // и ядро подставляет его само.
      tls.remove('fingerprint');
      tls.remove('alpn');
    }
    if (options.routing.direction == RoutingDirection.onlySelected) {
      final direct = outbounds.singleWhere(
        (dynamic out) => out['tag'] == 'direct',
      );
      outbounds.remove(direct);
      outbounds.insert(0, direct);
    }
    return result;
  }

  /// Go в режиме «напрямую» отдаёт порт 53 в freedom (до своего TUN-DNS
  /// 1.1.1.1) и резолвит сам через `localhost`. Здесь приложения спрашивают
  /// якорь 198.18.0.1, который freedom не достанет, а `localhost` для xray-rust —
  /// DNS-сервер с именем localhost:53, не системный резолвер (его при StaticOnly
  /// у ядра нет). Поэтому, как и в режиме «через VPN», запросы приложений
  /// принимает DNS-outbound и отвечает через DNS-модуль с выбранным сервером,
  /// но сам модуль (`dns-module`, и для своих поисков ядра) ходит в direct —
  /// мимо туннеля, защищёнными сокетами.
  static void _routeDnsDirect(
    Map<String, dynamic> result,
    VpnEngineOptions options,
  ) {
    result['dns'] = XrayConfigBuilder.buildResolverDnsBlock(options);
    final rules = (result['routing'] as Map)['rules'] as List<dynamic>;
    final goRule = rules.indexWhere(
      (dynamic r) =>
          r['port'] == '53' &&
          r['outboundTag'] == 'direct' &&
          r['inboundTag'] == null,
    );
    if (goRule < 0) throw StateError('Go direct-DNS rule not found');
    rules.replaceRange(goRule, goRule + 1, <Map<String, dynamic>>[
      {
        'type': 'field',
        'inboundTag': ['dns-module'],
        'outboundTag': 'direct',
      },
      {
        'type': 'field',
        'inboundTag': ['socks-in'],
        'port': '53',
        'network': 'udp,tcp',
        'outboundTag': 'dns-out',
      },
    ]);
  }

  /// Go отвечает на рекламные домены пустым NOERROR: DNS-сервер
  /// `rcode://success` со списком domains. xray-rust такой сервер не принимает,
  /// то же делает правило Return у DNS-outbound, через который идут DNS-запросы
  /// приложений (и с FakeDNS, и в режиме «напрямую»). Домены — те же, что у Go.
  static void _blockAdsInDnsOutbound(Map<String, dynamic> result) {
    final servers = (result['dns'] as Map)['servers'] as List<dynamic>;
    final adServer = servers.singleWhere(
      (dynamic s) => s is Map && s['address'] == 'rcode://success',
    );
    servers.remove(adServer);
    final outbounds = result['outbounds'] as List<dynamic>;
    final dnsOut = outbounds.indexWhere(
      (dynamic out) => out['protocol'] == 'dns',
    );
    // Go пишет dns-out литералом Map<String, String> — собираем заново.
    outbounds[dnsOut] = <String, dynamic>{
      ...outbounds[dnsOut] as Map,
      'settings': {
        'rules': [
          {'action': 'return', 'rCode': 0, 'domain': adServer['domains']},
        ],
      },
    };
  }

  /// xray-rust reads a DoT server's port only from its `tls://` URL and ignores
  /// the object's `port`, so a custom DoT port would silently become 853.
  /// A plain server keeps `port`, but its IPv6 literal must be unbracketed.
  static final _dotAuthorityWithPort =
      RegExp(r'^tls://(\[[^\]]*\]|[^:\[\]]+):\d+$');

  static void _adaptDnsServers(Map<String, dynamic> dns) {
    for (final dynamic server in dns['servers'] as List<dynamic>) {
      if (server is! Map) continue;
      final address = server['address'] as String;
      if (address.startsWith('tls://') && server['port'] is int) {
        final port = server.remove('port');
        // DnsServerConfig оставляет `]:port` у IPv6 в скобках; второй порт
        // xray-rust отвергает, поэтому порт из URL сохраняем как есть.
        if (!_dotAuthorityWithPort.hasMatch(address)) {
          server['address'] = '$address:$port';
        }
      } else if (address.startsWith('[') && address.endsWith(']')) {
        server['address'] = address.substring(1, address.length - 1);
      }
    }
  }

  static String buildJson(VpnConfig config, VpnEngineOptions options) =>
      jsonEncode(build(config, options));
}
