package com.example.document_app

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.widget.RemoteViews
import android.os.Bundle
import android.app.PendingIntent
import android.content.Intent

class DocVaultWidgetProvider : AppWidgetProvider() {

    private fun buildViews(context: Context): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.docvault_widget)

        val searchIntent = Intent(context, MainActivity::class.java).apply {
            putExtra("action", "search")
        } 
        val searchPendingIntent = PendingIntent.getActivity(
            context, 0, searchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val voiceIntent = Intent(context, MainActivity::class.java).apply {
            putExtra("action", "voice_search")
        }
        val voicePendingIntent = PendingIntent.getActivity(
            context, 1, voiceIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        views.setOnClickPendingIntent(R.id.search_container, searchPendingIntent)
        views.setOnClickPendingIntent(R.id.mic_icon, voicePendingIntent)

        return views
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (appWidgetId in appWidgetIds) {
            appWidgetManager.updateAppWidget(appWidgetId, buildViews(context))
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle
    ) {
        super.onAppWidgetOptionsChanged(context, appWidgetManager, appWidgetId, newOptions)
        appWidgetManager.updateAppWidget(appWidgetId, buildViews(context))
    }
}