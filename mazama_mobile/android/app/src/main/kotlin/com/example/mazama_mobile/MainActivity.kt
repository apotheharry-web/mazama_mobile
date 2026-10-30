package com.example.mazama_mobile

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private lateinit var textScanner: TextScanner

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        textScanner = TextScanner(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mazama/text_scanner")
            .setMethodCallHandler(textScanner)
        // The cart timers home-screen widget (CartTimersWidget.kt): the app sends it every cart's running timer.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mazama/cart_timer_widget")
            .setMethodCallHandler(CartTimersChannel(this))
        // specs/app-updates AU-R12/AU-R13: inspect a downloaded update and hand it to Android's installer (AppInstaller.kt).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mazama/app_installer")
            .setMethodCallHandler(AppInstaller(this))
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (!textScanner.onActivityResult(requestCode, resultCode, data)) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (!textScanner.onRequestPermissionsResult(requestCode, grantResults)) {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        }
    }
}
