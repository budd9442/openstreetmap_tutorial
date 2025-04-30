package com.example.open_street_map_example


import android.content.Context
import android.net.*
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL


class MainActivity: FlutterActivity() {
    private val CHANNEL = "esp32.network/bind"

    override fun configureFlutterEngine(flutterEngine: io.flutter.embedding.engine.FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "sendRequestToESP32") {
                val cmd = call.argument<String>("cmd") ?: "ON" // default to ON if not specified
                sendRequestToESP32(cmd)
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }

    private fun sendRequestToESP32(cmd: String) {
        val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build()

        connectivityManager.requestNetwork(request, object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                Thread {
                    try {
                        val url = URL("http://192.168.4.1/command?cmd=$cmd") // Example ESP32 AP IP
                        val conn = network.openConnection(url) as HttpURLConnection
                        conn.requestMethod = "GET"

                        val reader = BufferedReader(InputStreamReader(conn.inputStream))
                        val response = reader.readText()
                        reader.close()
                        conn.disconnect()

                        Log.d("ESP32", "Response: $response")
                    } catch (e: Exception) {
                        Log.e("ESP32", "Error: ${e.message}", e)
                    }
                }.start()
            }

            override fun onUnavailable() {
                Log.e("ESP32", "ESP32 network not available")
            }
        })
    }
}