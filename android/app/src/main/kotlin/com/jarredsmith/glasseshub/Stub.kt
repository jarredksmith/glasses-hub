package com.jarredsmith.glasseshub

import android.app.Application
import android.app.Service
import android.content.Intent
import android.os.Bundle
import android.os.IBinder
import android.service.notification.NotificationListenerService
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.Text

class HubApp : Application()
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) { super.onCreate(savedInstanceState); setContent { Text("Glasses Hub") } }
}
class HubService : Service() { override fun onBind(intent: Intent?): IBinder? = null }
class NoticeListener : NotificationListenerService()
