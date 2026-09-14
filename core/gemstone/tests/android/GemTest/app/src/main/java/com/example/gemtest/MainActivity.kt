package com.example.gemtest

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.example.gemtest.ui.theme.GemTestTheme
import kotlinx.coroutines.runBlocking
import uniffi.gemstone.*

private val nativeProvider = NativeProvider()

class MainActivity : ComponentActivity() {

    init {
        System.loadLibrary("gemstone")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            GemTestTheme {
                // A surface container using the 'background' color from the theme
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    ContentView("Gemstone lib version: " + libVersion())
                }
            }
        }
    }
}

@Composable
fun ContentView(text: String, modifier: Modifier = Modifier) {
    Column(modifier = Modifier.fillMaxSize()) {
        Text(
            text = text,
            modifier = modifier
        )
        Button(
            onClick = { fetchData() },
            modifier = Modifier.size(width = 120.dp, height = 80.dp)
        ) {
            Text(text = "Fetch Data")
        }
    }
}

fun fetchData() {
    println("Kotlin <> Rust")
    runBlocking {
        val target = AlienTarget(
            url = "https://httpbin.org/get?foo=bar",
            method = AlienHttpMethod.GET,
            headers = mapOf(
                "X-Header" to "X-Value"
            ),
            body = null
        )
        // 返回值是 AlienResponse —— uniffi::Object，Kotlin 侧没有 getter。
        // 它的用途是交给 Rust 消费，状态码/正文由 NativeProvider 在构造前打印。
        nativeProvider.request(target).use {
            println("request ok")
        }
    }
}

@Preview(showBackground = true)
@Composable
fun GreetingPreview() {
    GemTestTheme {
        ContentView("Android")
    }
}
