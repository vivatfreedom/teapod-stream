package com.teapodstream.teapodstream

import android.content.Context

internal object CoreBridge {
    const val ENGINE = "rust"
    fun diagnostics() = RustCore.diagnostics()
    fun versions() = mapOf("xray" to RustCore.VERSION, "tun2socks" to "Rust direct TUN")
    fun prepare(context: Context) = GeodataStore.directory(context).absolutePath
    fun activate(context: Context, revision: String): String {
        GeodataStore.activate(context, revision)
        return prepare(context)
    }
    // Замер кандидата для switchConfig поднимает временный инстанс Go-ядра; у xray-rust
    // такого API нет, и Dart в Rust-сборке его не вызывает. -1 — «не измерено».
    fun measureOutboundDelay(config: String, url: String): Long = -1L
}
