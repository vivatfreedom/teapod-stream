package org.xrayrust.mobile

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.nio.ByteBuffer

/**
 * Local nativeStats change: the counters appended after upstream's 19 reach Kotlin
 * at their header positions, and the TUN payload counters move while a flow is
 * still open — the outbound accounting snapshot adds bytes only when it closes.
 * Packets go through the core's packet I/O, so no VpnService or TUN fd is needed.
 */
@RunWith(AndroidJUnit4::class)
class TunStatsTest {
    private val client = byteArrayOf(10, 10, 0, 2)
    private val loopback = byteArrayOf(127, 0, 0, 1)

    @Test
    fun liveTunCountersReachKotlinWhileTheFlowIsOpen() {
        DatagramSocket(0, InetAddress.getByAddress(loopback)).use { echo ->
            Thread {
                val buffer = ByteArray(2048)
                try {
                    while (true) {
                        val packet = DatagramPacket(buffer, buffer.size)
                        echo.receive(packet)
                        echo.send(DatagramPacket(packet.data, packet.length, packet.socketAddress))
                    }
                } catch (_: Exception) {
                }
            }.apply { isDaemon = true }.start()

            XrayCore.create(CONFIG).use { core ->
                core.start()
                val payload = ByteArray(700) { (it * 7).toByte() }
                core.pushPacket(udpPacket(client, 49154, loopback, echo.localPort, payload))
                val deadline = System.nanoTime() + 5_000_000_000
                var echoed: ByteArray? = null
                while (echoed == null && System.nanoTime() < deadline) {
                    val reply = core.pollPacket()
                    if (reply == null) Thread.sleep(10) else echoed = udpPayload(reply)
                }
                assertNotNull("no UDP echo through the TUN packet path", echoed)
                assertTrue(payload.contentEquals(echoed))

                val stats = core.stats()
                assertEquals(payload.size.toLong(), stats.udpRemoteWrittenBytes)
                assertEquals(payload.size.toLong(), stats.udpRemoteReadBytes)
                assertTrue(stats.inboundPackets >= 1 && stats.outboundPackets >= 1)
                // Appended fields: constant budget, the open UDP flow, nothing on TCP.
                assertTrue("udpFlowLimit=${stats.udpFlowLimit}", stats.udpFlowLimit > 0)
                assertTrue("activeUdpFlows=${stats.activeUdpFlows}", stats.activeUdpFlows >= 1)
                assertEquals(0L, stats.activeTcpFlows)
                assertEquals(0L, stats.tcpRemoteReadBytes + stats.tcpRemoteWrittenBytes)
                assertEquals(0L, stats.tunFdReadLoopExits + stats.tunFdWriteLoopExits)
                // Why the app reads live TUN counters: the flow is still open.
                val direct = core.outboundAccountingSnapshot().outbounds
                    .firstOrNull { it.outboundTag == "direct" }
                assertEquals(0L, direct?.downlinkBytes ?: 0L)
                core.stop()
            }
        }
    }

    private fun udpPacket(src: ByteArray, srcPort: Int, dst: ByteArray, dstPort: Int, payload: ByteArray): ByteArray {
        val udpLength = 8 + payload.size
        val packet = ByteBuffer.allocate(20 + udpLength)
            .put(0x45).put(0).putShort((20 + udpLength).toShort()).putShort(0).putShort(0x4000)
            .put(64).put(17).putShort(0).put(src).put(dst)
            .putShort(srcPort.toShort()).putShort(dstPort.toShort()).putShort(udpLength.toShort())
            .putShort(0).put(payload)
            .array()
        packet.putChecksum(10, checksum(packet, 0, 20, 0))
        val pseudo = words(src) + words(dst) + 17 + udpLength
        packet.putChecksum(26, checksum(packet, 20, udpLength, pseudo).takeIf { it != 0 } ?: 0xffff)
        return packet
    }

    private fun udpPayload(packet: ByteArray): ByteArray? {
        if (packet.size < 28 || packet[0].toInt() shr 4 != 4 || packet[9].toInt() != 17) return null
        val headerLength = (packet[0].toInt() and 0x0f) * 4
        val udpLength = ((packet[headerLength + 4].toInt() and 0xff) shl 8) or
            (packet[headerLength + 5].toInt() and 0xff)
        return packet.copyOfRange(headerLength + 8, headerLength + udpLength)
    }

    private fun words(address: ByteArray): Long =
        (((address[0].toInt() and 0xff) shl 8) or (address[1].toInt() and 0xff)).toLong() +
            (((address[2].toInt() and 0xff) shl 8) or (address[3].toInt() and 0xff)).toLong()

    private fun checksum(data: ByteArray, offset: Int, length: Int, initial: Long): Int {
        var sum = initial
        var i = offset
        while (i < offset + length) {
            val high = data[i].toInt() and 0xff
            val low = if (i + 1 < offset + length) data[i + 1].toInt() and 0xff else 0
            sum += ((high shl 8) or low).toLong()
            i += 2
        }
        while (sum shr 16 != 0L) sum = (sum and 0xffff) + (sum shr 16)
        return (sum.inv() and 0xffff).toInt()
    }

    private fun ByteArray.putChecksum(offset: Int, value: Int) {
        this[offset] = (value shr 8).toByte()
        this[offset + 1] = value.toByte()
    }

    private companion object {
        const val CONFIG = """{"inbounds":[{"tag":"tun-in","protocol":"tun"}],
            "outbounds":[{"tag":"direct","protocol":"freedom"}]}"""
    }
}
