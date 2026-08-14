package com.deevyansh.docezy

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.os.Build
import android.speech.RecognizerIntent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class MainActivity : FlutterActivity() {

    private val CHANNEL = "document_app/widget"
    private var methodChannel: MethodChannel? = null

    private val SPEECH_REQUEST_CODE = 100
    private var pendingSpeechResult: MethodChannel.Result? = null

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
                "startSpeechRecognition" -> {
                    pendingSpeechResult = result
                    startNativeSpeechRecognition()
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startNativeSpeechRecognition() {
        val speechIntent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault())
            putExtra(RecognizerIntent.EXTRA_PROMPT, "Speak now")
        }
        try {
            startActivityForResult(speechIntent, SPEECH_REQUEST_CODE)
        } catch (e: Exception) {
            pendingSpeechResult?.error("NO_SPEECH_ENGINE", "Speech recognition not available on this device", null)
            pendingSpeechResult = null
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == SPEECH_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK && data != null) {
                val results = data.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
                val spokenText = results?.firstOrNull() ?: ""
                pendingSpeechResult?.success(spokenText)
            } else {
                // user cancelled or no speech detected
                pendingSpeechResult?.success(null)
            }
            pendingSpeechResult = null
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