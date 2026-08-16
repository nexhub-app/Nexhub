package com.nexhub.app

import android.view.KeyEvent
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var volumeKeyInterceptionEnabled = false
    private var volumeEventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Method channel to enable/disable volume key interception
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "nexhub/volume_control"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "enableInterception" -> {
                    volumeKeyInterceptionEnabled = true
                    result.success(null)
                }
                "disableInterception" -> {
                    volumeKeyInterceptionEnabled = false
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // Event channel for volume key events
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "nexhub/volume_events"
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    volumeEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    volumeEventSink = null
                }
            }
        )
    }

    // Bug1 修复：把音量键拦截从 onKeyDown 提升到 dispatchKeyEvent——在 view 层级
    // （FlutterView）消费按键之前先拿到事件，避免 FlutterView 先吃掉按键导致
    // Activity.onKeyDown 收不到（实机音量键翻页完全无响应的根因）。
    // 拦截开启时：仅 ACTION_DOWN 向 Flutter 派发事件；DOWN 与 UP 均返回 true 完全
    // 消费，阻止系统音量条弹出。未开启时走默认分发（音量键正常调系统音量）。
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (volumeKeyInterceptionEnabled) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_VOLUME_DOWN -> {
                    if (event.action == KeyEvent.ACTION_DOWN) {
                        volumeEventSink?.success("volume_down")
                    }
                    return true
                }
                KeyEvent.KEYCODE_VOLUME_UP -> {
                    if (event.action == KeyEvent.ACTION_DOWN) {
                        volumeEventSink?.success("volume_up")
                    }
                    return true
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }
}
