package org.xrayrust.mobile

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.DataInputStream
import java.io.File
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.security.KeyStore
import java.security.cert.CertificateFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManagerFactory

/** VLESS combinations and Hysteria2 (cases with `udpEcho` also relay SOCKS UDP). */
@RunWith(AndroidJUnit4::class)
class VlessTransportInteropTest {
    @Test fun productionProfilesExchangeDataWithReferenceXray() {
        val path = InstrumentationRegistry.getArguments().getString("interopConfig")
        assumeTrue("Run scripts/test-rust-transports.py to start the local reference server", path != null)
        val fixture = JSONObject(File(requireNotNull(path)).readText())
        val trust = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null)
            val cert = CertificateFactory.getInstance("X.509").generateCertificate(
                fixture.getString("certificatePem").byteInputStream())
            setCertificateEntry("local-test", cert)
        }
        val trustManager = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(trust) }
        val ssl = SSLContext.getInstance("TLS").apply { init(null, trustManager.trustManagers, null) }
        val cases = fixture.getJSONArray("cases")
        val failures = mutableListOf<String>()
        for (index in 0 until cases.length()) {
            val entry = cases.getJSONObject(index)
            val name = entry.getString("name")
            val config = JSONObject(entry.getString("config"))
            val inbounds = config.getJSONArray("inbounds")
            val port = ServerSocket(0).use { it.localPort }
            for (i in 0 until inbounds.length()) {
                val inbound = inbounds.getJSONObject(i)
                if (inbound.getString("protocol") == "socks") inbound.put("port", port)
            }
            try {
                XrayCore.create(config.toString()).use { core ->
                    core.start()
                    socks(port, fixture.getInt("echoPort")).use { echo(it) }
                    Log.i("TeapodVlessInterop", "$name: plain echo passed")
                    // Inner TLS exercises Vision's transition as well as its
                    // initial framing. Only the generated test CA is trusted.
                    socks(port, fixture.getInt("tlsEchoPort")).use { tunnel ->
                        (ssl.socketFactory.createSocket(tunnel, "cover.example", fixture.getInt("tlsEchoPort"), true) as SSLSocket).use {
                            it.soTimeout = 15000
                            it.sslParameters = it.sslParameters.apply { endpointIdentificationAlgorithm = "HTTPS" }
                            it.startHandshake()
                            Log.i("TeapodVlessInterop", "$name: inner TLS handshake passed")
                            echo(it)
                        }
                    }
                    if (entry.optBoolean("udpEcho")) {
                        udpEcho(port, fixture.getInt("udpEchoPort"))
                        Log.i("TeapodVlessInterop", "$name: SOCKS UDP echo passed")
                    }
                    core.stop()
                }
                Log.i("TeapodVlessInterop", "$name: plain and inner-TLS payloads verified")
            } catch (error: Throwable) {
                Log.e("TeapodVlessInterop", "$name failed", error)
                failures.add(name + ": " + error.javaClass.simpleName)
            }
        }
        check(failures.isEmpty()) { failures.joinToString("; ") }
    }

    private fun socks(port: Int, target: Int): Socket {
        val client = Socket("127.0.0.1", port)
        try {
            client.soTimeout = 15000
            val out = client.getOutputStream()
            val input = DataInputStream(client.getInputStream())
            out.write(byteArrayOf(5, 1, 0))
            assertEquals(5, input.readUnsignedByte()); assertEquals(0, input.readUnsignedByte())
            out.write(byteArrayOf(5, 1, 0, 1, 127, 0, 0, 1, (target shr 8).toByte(), target.toByte()))
            assertEquals(5, input.readUnsignedByte()); assertEquals(0, input.readUnsignedByte())
            input.readUnsignedByte()
            val bytes = when (input.readUnsignedByte()) { 1 -> 4; 4 -> 16; 3 -> input.readUnsignedByte(); else -> error("Invalid SOCKS address") }
            input.readFully(ByteArray(bytes + 2))
            return client
        } catch (error: Throwable) {
            client.close()
            throw error
        }
    }

    /** SOCKS5 UDP ASSOCIATE; 3000 bytes exceed one 1200-byte QUIC datagram. */
    private fun udpEcho(port: Int, target: Int) {
        Socket("127.0.0.1", port).use { control ->
            control.soTimeout = 15000
            val out = control.getOutputStream()
            val input = DataInputStream(control.getInputStream())
            out.write(byteArrayOf(5, 1, 0))
            assertEquals(5, input.readUnsignedByte()); assertEquals(0, input.readUnsignedByte())
            out.write(byteArrayOf(5, 3, 0, 1, 0, 0, 0, 0, 0, 0))
            assertEquals(5, input.readUnsignedByte()); assertEquals(0, input.readUnsignedByte())
            input.readUnsignedByte()
            val host = when (input.readUnsignedByte()) {
                1 -> InetAddress.getByAddress(ByteArray(4).also { input.readFully(it) })
                4 -> InetAddress.getByAddress(ByteArray(16).also { input.readFully(it) })
                3 -> InetAddress.getByName(String(ByteArray(input.readUnsignedByte()).also { input.readFully(it) }))
                else -> error("Invalid SOCKS address")
            }
            val relay = InetSocketAddress(
                if (host.isAnyLocalAddress) InetAddress.getLoopbackAddress() else host,
                input.readUnsignedShort())
            DatagramSocket().use { udp ->
                udp.soTimeout = 5000
                val header = byteArrayOf(0, 0, 0, 1, 127, 0, 0, 1, (target shr 8).toByte(), target.toByte())
                for (size in intArrayOf(64, 1000, 3000)) {
                    val payload = ByteArray(size) { ((it * 31 + size) and 255).toByte() }
                    val datagram = header + payload
                    val buffer = ByteArray(65536)
                    var reply: ByteArray? = null
                    // UDP may lose a datagram; the payload itself must come back intact.
                    for (attempt in 0 until 3) {
                        udp.send(DatagramPacket(datagram, datagram.size, relay))
                        val packet = DatagramPacket(buffer, buffer.size)
                        try {
                            udp.receive(packet)
                        } catch (_: SocketTimeoutException) {
                            continue
                        }
                        reply = buffer.copyOf(packet.length)
                        break
                    }
                    val received = requireNotNull(reply) { "No UDP reply for $size bytes" }
                    check(received.size > 4 && received[2].toInt() == 0) { "Invalid SOCKS UDP reply" }
                    val offset = when (received[3].toInt()) {
                        1 -> 10
                        4 -> 22
                        3 -> 7 + (received[4].toInt() and 255)
                        else -> error("Invalid SOCKS UDP address")
                    }
                    assertArrayEquals(payload, received.copyOfRange(offset, received.size))
                }
            }
        }
    }

    private fun echo(socket: Socket) {
        val input = DataInputStream(socket.getInputStream())
        val out = socket.getOutputStream()
        repeat(4) { round ->
            val payload = ByteArray(32 * 1024) { ((it * 37 + round) and 255).toByte() }
            out.write(payload); out.flush()
            val received = ByteArray(payload.size)
            input.readFully(received)
            assertArrayEquals(payload, received)
        }
    }
}
