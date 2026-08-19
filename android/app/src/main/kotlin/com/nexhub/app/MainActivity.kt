package com.nexhub.app

import android.content.Context
import android.util.Log
import android.view.KeyEvent
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private var volumeKeyInterceptionEnabled = false
    private var volumeEventSink: EventChannel.EventSink? = null
    // 诊断：开启拦截但 EventSink 未就绪时只告警一次，避免每条按键刷日志。
    private var volumeSinkWarned = false

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
                    // 订阅建立即重置告警标记，便于下次重新开启时再次提示。
                    volumeSinkWarned = false
                }

                override fun onCancel(arguments: Any?) {
                    volumeEventSink = null
                }
            }
        )
    }

    // 后台播放修复：自定义 Activity（继承 FlutterFragmentActivity）必须覆写
    // provideFlutterEngine，把 Flutter 引擎交由 audio_service 插件托管——
    // 否则前台服务/媒体按钮回调在尝试取引擎时会抛
    // 「The Activity class declared ... wrong or has not provided the correct
    // FlutterEngine」，导致 AudioService.init 失败、后台播放与通知失效。
    // 返回 null 时 Flutter 框架会自动新建引擎（首启场景），不会崩溃。
    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        return AudioServicePlugin.getFlutterEngine(context)
    }

    // Bug1 修复：把音量键拦截从 onKeyDown 提升到 dispatchKeyEvent——在 view 层级
    // （FlutterView）消费按键之前先拿到事件，避免 FlutterView 先吃掉按键导致
    // Activity.onKeyDown 收不到（实机音量键翻页完全无响应的根因）。
    // 拦截开启时：仅 ACTION_DOWN 向 Flutter 派发事件；DOWN 与 UP 均返回 true 完全
    // 消费，阻止系统音量条弹出。未开启时走默认分发（音量键正常调系统音量）。
    //
    // 安全守卫：仅当 EventSink 已就绪（事件通道订阅建立）时才消费音量键。否则
    // 回落系统默认处理——避免「拦截已开但 sink 未就绪」时按键被静默吞掉
    // （表现为音量键完全无响应、既无翻页也无系统音量反馈）。
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (volumeKeyInterceptionEnabled && volumeEventSink != null) {
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
        } else if (volumeKeyInterceptionEnabled && volumeEventSink == null && !volumeSinkWarned) {
            // 诊断：开启拦截但 EventSink 未就绪（订阅未建立），事件将走系统默认。
            volumeSinkWarned = true
            Log.w(
                "NexHubVolume",
                "音量键拦截已开启但 EventSink 未就绪（事件通道订阅未建立），按键走系统默认而非翻页。",
            )
        }
        return super.dispatchKeyEvent(event)
    }
}
