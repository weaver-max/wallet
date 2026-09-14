package com.example.gemtest

import io.ktor.client.*
import io.ktor.client.call.body
import io.ktor.client.engine.cio.*
import io.ktor.client.request.*
import io.ktor.http.*
import uniffi.gemstone.*

class NativeProvider: AlienProvider {
    val client = HttpClient(CIO) {
        expectSuccess = true
    }

    fun close() {
        client.close()
    }

    override fun getEndpoint(chain: Chain): String {
        return "http://localhost:8080"
    }

    override suspend fun request(target: AlienTarget): AlienResponse {
        val parsedUrl = try {
            Url(target.url)
        } catch (e: Throwable) {
            throw AlienException.RequestException("invalid url: ${target.url}")
        }

        val response = client.request {
            method = HttpMethod(alienMethodToString(target.method))
            url.takeFrom(parsedUrl)
            headers {
                target.headers?.forEach { (key, value) -> append(key, value) }
            }
            target.body?.let { setBody(it) }
        }

        val bytes: ByteArray = response.body()
        val status = response.status.value

        // AlienResponse 是 uniffi::Object（不透明句柄），Kotlin 侧只能构造、读不出内容。
        // 所以要打日志只能在包装之前打，调用方拿到的对象是给 Rust 消费的。
        println("[NativeProvider] ${target.url} -> $status, ${bytes.size} bytes")

        return AlienResponse(status.toUShort(), bytes)
    }
}
