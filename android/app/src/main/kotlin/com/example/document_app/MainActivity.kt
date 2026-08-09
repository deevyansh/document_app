package com.example.document_app

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "document_app/widget"
    private var methodChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getLaunchAction" -> {
                    val action = intent.getStringExtra("action")
                    result.success(action)
                    intent.removeExtra("action")
                }
                "isPinWidgetSupported" -> {
                    val supported = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        AppWidgetManager.getInstance(this).isRequestPinAppWidgetSupported
                    } else {
                        false
                    }
                    result.success(supported)
                }
                "requestPinWidget" -> {
                    result.success(requestPinWidget())
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun requestPinWidget(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val appWidgetManager = AppWidgetManager.getInstance(this)
        if (!appWidgetManager.isRequestPinAppWidgetSupported) return false
        val widgetComponent = ComponentName(this, DocVaultWidgetProvider::class.java)
        return appWidgetManager.requestPinAppWidget(widgetComponent, null, null)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)

        val action = intent.getStringExtra("action")
        if (action != null) {
            methodChannel?.invokeMethod("onWidgetLaunch", action)
            intent.removeExtra("action")
        }
    }
}