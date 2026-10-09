package com.teapodstream.teapodstream

import android.net.ConnectivityManager
import android.net.InetAddresses
import android.net.Network
import android.net.NetworkCapabilities
import android.net.VpnService
import org.json.JSONArray
import org.json.JSONObject
import org.xrayrust.mobile.XrayCore
import org.xrayrust.mobile.XrayDnsBootstrapMode
import org.xrayrust.mobile.XrayTunFileDescriptor
import org.xrayrust.mobile.XrayTunRuntimeProfile
import org.xrayrust.mobile.XrayTunStats
import java.net.URI
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/** Owns one Rust runtime. Android owns the borrowed TUN descriptor. */
internal object RustCore {
    const val VERSION = "xray-rust 0.7.0"
    private const val RESOLVE_TIMEOUT_SECONDS = 5L
    private const val RESOLVE_TIMEOUT_MESSAGE = "Не удалось вовремя разрешить адрес VPN-сервера"
    private const val RESOLVE_DNS_TIMEOUT_MESSAGE = "Не удалось вовремя разрешить адрес DNS-сервера"
    private var core: XrayCore? = null
    private var lastRxBytes = 0L
    private var lastRxAt = 0L
    private var lastTcpTxBytes = 0L
    private var lastTcpTxAt = 0L
    private var geodataRevision = ""
    // A timed-out platform resolver may ignore interruption. Bound its workers
    // as well as the wait, so repeated reconnects cannot leak resolver threads.
    private val resolver = ThreadPoolExecutor(0, 2, 30, TimeUnit.SECONDS,
        SynchronousQueue(), { work -> Thread(work, "rust-dns-bootstrap").apply { isDaemon = true } })

    /**
     * Resolve every proxy server name before installing TUN, including during a
     * reconnect. StaticOnly bootstrap lets the core resolve carrier hosts only
     * from `dns.hosts`; IP literals need no entry. The same holds for DNS server
     * names in direct DNS mode, see [directDnsServerNames].
     */
    fun prepareConfig(config: String, service: VpnService): String {
        val json = JSONObject(config)
        val names = serverNames(json.getJSONArray("outbounds"))
            .associateWith { RESOLVE_TIMEOUT_MESSAGE to "Не удалось разрешить адрес VPN-сервера" } +
            directDnsServerNames(json).associateWith {
                RESOLVE_DNS_TIMEOUT_MESSAGE to "Не удалось разрешить адрес DNS-сервера $it"
            }
        if (names.isEmpty()) return config
        val dns = json.getJSONObject("dns")
        val hosts = dns.optJSONObject("hosts") ?: JSONObject().also { dns.put("hosts", it) }
        val network = physicalNetwork(service)
        // One budget for all names, so several servers cannot stack 5 s waits.
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(RESOLVE_TIMEOUT_SECONDS)
        for ((name, messages) in names) {
            val (timeoutMessage, failureMessage) = messages
            val remaining = deadline - System.nanoTime()
            if (remaining <= 0) throw TimeoutException(timeoutMessage)
            val lookup = resolver.submit<List<String>> {
                network.getAllByName(name).mapNotNull { it.hostAddress }
            }
            val addresses = try {
                lookup.get(remaining, TimeUnit.NANOSECONDS)
            } catch (_: TimeoutException) {
                throw TimeoutException(timeoutMessage)
            } finally {
                lookup.cancel(true)
            }
            check(addresses.isNotEmpty()) { failureMessage }
            hosts.put("full:$name", JSONArray(addresses))
        }
        // Literal-IP DNS and the bundled DoH/DoT presets carry static hosts; DNS
        // through the VPN resolves a DNS server name remotely. Never recurse through TUN.
        return json.toString()
    }

    /**
     * DNS server names to pin when the DNS module (`dns.tag`) is routed to `direct`
     * (the Rust direct DNS mode). Through Freedom, StaticOnly bootstrap finds a
     * server name only in `dns.hosts`, so a custom DoH/DoT/UDP server given by name
     * would fail; through VLESS/Hysteria the server resolves it and nothing leaks
     * here. Names already in `dns.hosts` (the presets' fallback IPs) stay as given.
     */
    private fun directDnsServerNames(json: JSONObject): Set<String> {
        val dns = json.optJSONObject("dns") ?: return emptySet()
        val tag = dns.optString("tag").takeIf { it.isNotEmpty() } ?: return emptySet()
        val rules = json.optJSONObject("routing")?.optJSONArray("rules") ?: return emptySet()
        val direct = (0 until rules.length()).any { i ->
            val rule = rules.optJSONObject(i) ?: return@any false
            val tags = rule.optJSONArray("inboundTag") ?: return@any false
            rule.optString("outboundTag") == "direct" &&
                (0 until tags.length()).any { tags.optString(it) == tag }
        }
        if (!direct) return emptySet()
        val hosts = dns.optJSONObject("hosts")
        val servers = dns.optJSONArray("servers") ?: return emptySet()
        val names = linkedSetOf<String>()
        for (i in 0 until servers.length()) {
            val address = servers.optJSONObject(i)?.optString("address") ?: servers.optString(i)
            // `https://h[:p]/path`, `tls://h[:p]`, `tcp://h` or a bare UDP server.
            val host = if ("://" in address) runCatching { URI(address).host }.getOrNull() else address
            val name = host?.removeSurrounding("[", "]")
            if (name.isNullOrEmpty() || InetAddresses.isNumericAddress(name)) continue
            if (hosts?.has(name) == true || hosts?.has("full:$name") == true) continue
            names.add(name)
        }
        return names
    }

    /** Server host names of VLESS (every vnext entry) and Hysteria outbounds. */
    private fun serverNames(outbounds: JSONArray): Set<String> {
        val names = linkedSetOf<String>()
        for (i in 0 until outbounds.length()) {
            val outbound = outbounds.getJSONObject(i)
            val settings = outbound.optJSONObject("settings") ?: continue
            when (outbound.optString("protocol")) {
                "vless" -> {
                    val vnext = settings.getJSONArray("vnext")
                    for (j in 0 until vnext.length()) names.add(vnext.getJSONObject(j).getString("address"))
                }
                "hysteria" -> names.add(settings.getString("address"))
            }
        }
        names.removeAll { InetAddresses.isNumericAddress(it.removeSurrounding("[", "]")) }
        return names
    }

    private fun physicalNetwork(service: VpnService): Network {
        val cm = service.getSystemService(ConnectivityManager::class.java)
        val candidates = (listOfNotNull(cm.activeNetwork) + cm.allNetworks).distinct().filter {
            val caps = cm.getNetworkCapabilities(it)
            caps != null && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
        }
        return candidates.firstOrNull {
            cm.getNetworkCapabilities(it)?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
        } ?: candidates.firstOrNull() ?: error("Нет доступной сети для подключения VPN")
    }

    @Synchronized
    fun start(config: String, service: VpnService, tunFd: Int) {
        check(core == null) { "Rust runtime is already running" }
        val runtime = GeodataStore.withDirectory(service) { geodata ->
            geodataRevision = geodata.name
            XrayCore.create(
                configJson = config,
                vpnService = service,
                tunFileDescriptor = XrayTunFileDescriptor(tunFd),
                tunRuntimeProfile = XrayTunRuntimeProfile.Mobile,
                dnsBootstrapMode = XrayDnsBootstrapMode.StaticOnly,
                geodataDirectory = geodata,
            )
        }
        try {
            runtime.start()
            core = runtime
            lastRxBytes = 0
            lastRxAt = 0
            lastTcpTxBytes = 0
            lastTcpTxAt = 0
        } catch (error: Throwable) {
            runtime.close()
            throw error
        }
    }

    /** Must finish before the service closes or reuses its borrowed fd. */
    @Synchronized
    fun stop() {
        val runtime = core ?: return
        core = null
        try {
            runtime.stop()
        } finally {
            runtime.close()
        }
    }

    @Synchronized
    fun isRunning(): Boolean = core != null

    /**
     * Upload/download payload bytes of TUN flows, counted live as the core writes to
     * and reads from each outbound (proxy and direct alike, DNS upstream exchanges
     * included). The outbound accounting snapshot adds a connection only once it
     * closes, so speed stayed at zero during a long transfer. The app's own SOCKS
     * probe is not TUN traffic and is left out, as in Go's tun2socks counters.
     */
    @Synchronized
    fun trafficTotals(): Pair<Long, Long> {
        val stats = core?.let(::tunStats) ?: return 0L to 0L
        sampleRx(stats)
        return (stats.tcpRemoteWrittenBytes + stats.udpRemoteWrittenBytes) to
            (stats.tcpRemoteReadBytes + stats.udpRemoteReadBytes)
    }

    /** Null when the runtime is stopped or its stats cannot be read. */
    private fun tunStats(runtime: XrayCore): XrayTunStats? =
        try { runtime.stats() } catch (_: RuntimeException) { null }

    /**
     * lastRx is the last time data arrived from the network for a TUN flow: TCP or
     * UDP remote read bytes grew. outboundPackets also counted packets the core
     * writes itself (DNS/FakeDNS answers, ICMP echo replies, TCP handshakes and
     * ACKs), so a silent server could look alive. Resolution is the sampling
     * period: the stats thread samples every 1 s, or 10 s with the screen off.
     */
    private fun sampleRx(stats: XrayTunStats) {
        val now = System.currentTimeMillis()
        val bytes = stats.tcpRemoteReadBytes + stats.udpRemoteReadBytes
        if (bytes > lastRxBytes) lastRxAt = now
        lastRxBytes = bytes
        // TCP payload the outbound accepted. A reply-less upload (HTTP/1.1 PUT, FTP STOR)
        // is alive while it moves; a half-open upstream stops accepting writes once the
        // socket buffer fills. UDP sends never block, so they are not proof of life.
        if (stats.tcpRemoteWrittenBytes > lastTcpTxBytes) lastTcpTxAt = now
        lastTcpTxBytes = stats.tcpRemoteWrittenBytes
    }

    @Synchronized
    fun lastRxActivityMs(): Long {
        core?.let(::tunStats)?.let(::sampleRx)
        return lastRxAt
    }

    /**
     * TUN stall watchdog only: the last downstream payload or accepted TCP upload.
     * Go's tun2socks refreshes lastRx with every TUN write, including the ACKs for an
     * app's upload; xray-rust ACKs locally, so a long reply-less upload would look
     * stalled on reads alone. Zero until the first downstream byte, as before.
     */
    @Synchronized
    fun lastTunActivityMs(): Long {
        core?.let(::tunStats)?.let(::sampleRx)
        return if (lastRxAt > 0) maxOf(lastRxAt, lastTcpTxAt) else 0L
    }

    /**
     * Why the TUN data path is down, or null while it works — the counterpart of
     * Go's isTunRunning(). xray-rust keeps the runtime up after a TUN fd read or
     * write loop stops on an fd error (for example a descriptor closed by the
     * system), so isRunning() alone would report a tunnel that no longer moves packets.
     */
    @Synchronized
    fun tunFailure(): String? {
        val runtime = core ?: return "runtime stopped"
        val stats = tunStats(runtime) ?: return "TUN stats unavailable"
        sampleRx(stats)
        if (stats.tunFdReadLoopExits > 0 || stats.tunFdWriteLoopExits > 0) {
            return "TUN fd loop exited (read=${stats.tunFdReadLoopExits}, write=${stats.tunFdWriteLoopExits})"
        }
        return null
    }

    fun isTunRunning(): Boolean = tunFailure() == null

    /** Open TCP + UDP flows of the TUN stack, like tun2socks' active connections. */
    @Synchronized
    fun tunActiveFlows(): Long {
        val stats = core?.let(::tunStats) ?: return 0
        sampleRx(stats)
        return stats.activeTcpFlows + stats.activeUdpFlows
    }

    /** Connections tracked by the core, including the SOCKS probe; diagnostics only. */
    @Synchronized
    fun activeConnections(): Long = core?.connectionSnapshot()?.connections?.size?.toLong() ?: 0

    @Synchronized
    fun closeConnections(): Int {
        val runtime = core ?: return 0
        return runtime.connectionSnapshot().connections.count {
            runCatching { runtime.closeConnection(it.id) }.isSuccess
        }
    }

    /**
     * Snapshot for the heartbeat log. A failed core query leaves its fields out
     * instead of throwing: the heartbeat would count an exception as a failed
     * probe, and PASSIVE runs no probe at all.
     */
    @Synchronized
    fun diagnostics(): String {
        val runtime = core ?: return ""
        val stats = tunStats(runtime) ?: return ""
        sampleRx(stats)
        val json = JSONObject().apply {
            put("engine", VERSION)
            put("tunBackend", "fd")
            put("geodata", geodataRevision)
            put("inboundPackets", stats.inboundPackets)
            put("outboundPackets", stats.outboundPackets)
            put("droppedPackets", stats.droppedPackets)
            // Live payload bytes of TUN flows; tcpDown + udpDown drive lastRx.
            put("tcpUp", stats.tcpRemoteWrittenBytes)
            put("tcpDown", stats.tcpRemoteReadBytes)
            put("udpUp", stats.udpRemoteWrittenBytes)
            put("udpDown", stats.udpRemoteReadBytes)
            put("tcpFlows", stats.activeTcpFlows)
            put("udpFlows", stats.activeUdpFlows)
            put("tcpOpenErrors", stats.tcpOpenErrors)
            put("udpOpenErrors", stats.udpOpenErrors)
            put("remoteReadErrors", stats.tcpRemoteReadErrors + stats.udpRemoteReadErrors)
            put("remoteWriteErrors", stats.tcpRemoteWriteErrors + stats.udpRemoteWriteErrors)
            put("tunFdLoopExits", stats.tunFdReadLoopExits + stats.tunFdWriteLoopExits)
            put("tunFdTransientErrors", stats.tunFdTransientIoErrors)
        }
        return try {
            json.put("routingRules", runtime.routingPolicySnapshot().ruleCount)
            json.put("activeConnections", activeConnections())
            // Closed connections only: the core adds a connection's bytes when it ends.
            json.put("outbounds", JSONArray(runtime.outboundAccountingSnapshot().outbounds.map {
                JSONObject().put("tag", it.outboundTag).put("upload", it.uplinkBytes)
                    .put("download", it.downlinkBytes).put("connections", it.openedConnections)
            }))
            json.toString()
        } catch (_: RuntimeException) {
            json.toString()
        }
    }
}
