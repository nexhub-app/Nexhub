package com.nexhub.app

import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.graphics.drawable.Icon
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.MediaStore
import android.util.Log
import android.util.Rational
import android.view.KeyEvent
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterFragmentActivity() {
    private var volumeKeyInterceptionEnabled = false
    private var volumeEventSink: EventChannel.EventSink? = null
    // 诊断：开启拦截但 EventSink 未就绪时只告警一次，避免每条按键刷日志。
    private var volumeSinkWarned = false

    // ──  系统 PiP 窗口动作（Android O+）──────────────────────────────
    // floating 包仅支持进出 PiP，不支持窗口内自定义动作（RemoteAction）；
    // 这里在应用侧扩展 nexhub/pip（下发动作）与 nexhub/pip_events（回传点击），
    // 经动态 BroadcastReceiver 把 PiP 窗口按钮点击转成 Flutter 事件。
    private var pipEventSink: EventChannel.EventSink? = null
    private var pipActions: List<RemoteAction> = emptyList()
    private var pipReceiverRegistered = false
    // 进入 PiP 后延迟刷新动作参数：转场动画进行中同步调
    // setPictureInPictureParams 会与系统 PiP 转场互相干扰（闪烁/卡顿）。
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pipRefreshRunnable = Runnable { refreshPipParams() }
    private val pipActionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != PIP_ACTION) return
            val id = intent.getStringExtra(EXTRA_ACTION_ID) ?: return
            pipEventSink?.success("action:$id")
        }
    }

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

        // Method channel: install APK via FileProvider (in-app update)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "nexhub/update_install"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("bad_args", "path is null", null)
                        return@setMethodCallHandler
                    }
                    try {
                        installApk(File(path))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("install_failed", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Method channel: MD3 触觉反馈（原生 Vibrator 直接播放官方触感原语，
        // 不依赖系统「触摸反馈」设置——Flutter 的 HapticFeedback 在部分
        // 设备/系统设置下被静默，导致手机上感觉不到震动）。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            HAPTIC_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "effect" -> {
                    try {
                        vibrateEffect(call.argument<String>("effect") ?: "click")
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("vibrate_failed", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Method channel: 读取系统 WebView Cookie 存储（android.webkit.CookieManager），
        // 与内嵌 InAppWebView 登录共享同一份 cookie。flutter_inappwebview 的
        // CookieManager 在某些版本/配置下与 InAppWebView 不是同一存储，导致「登录了
        // 但取不到 cookie」。直接读系统 CookieManager 是最可靠的做法：网络层经此通道
        // 拿到会话 cookie 回灌，跳过 flutter_inappwebview 的中间层。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "nexhub/system_cookie"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getCookieHeader" -> {
                    val url = call.argument<String>("url")
                    if (url == null) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    try {
                        val cookies = android.webkit.CookieManager.getInstance().getCookie(url)
                        result.success(cookies)
                    } catch (e: Exception) {
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Method channel: 保存图片到公共外部存储相册（长按图片菜单「保存」）。
        // Android 10+（分区存储）经 MediaStore 写公共相册 Pictures/NexHub，
        // 无需任何存储权限；Android 9- 直写公共 Pictures 目录，运行时
        // WRITE_EXTERNAL_STORAGE 由 Dart 侧（permission_handler）先申请。
        // 写盘放独立线程，避免大图阻塞主线程造成掉帧/ANR。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "nexhub/media_store"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                "saveImage" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val fileName = call.argument<String>("fileName")
                    val mime = call.argument<String>("mime") ?: "image/jpeg"
                    if (bytes == null || fileName == null) {
                        result.error("bad_args", "bytes/fileName is null", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            result.success(saveImageToPublicPictures(bytes, fileName, mime))
                        } catch (e: Exception) {
                            result.error("save_failed", e.message, null)
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }

        // Method channel: 让源自带 WebView 跟随源「网络覆盖」（hosts/DoH/手动代理）。
        // 经 AndroidX ProxyController 把源域名导到本地正向代理（DNS 由 DnsResolver
        // 按源 hosts 解析，绕开 DNS 污染）；API 28 以下不支持，安全回落（不生效）。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "nexhub/webview_proxy"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setProxyOverride" -> {
                    val pacUrl = call.argument<String>("pacUrl")
                    val proxyUrl = call.argument<String>("proxyUrl")
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        try {
                            val rule = pacUrl ?: proxyUrl
                            if (rule == null) {
                                result.success(false)
                                return@setMethodCallHandler
                            }
                            val proxyConfig = ProxyConfig.Builder()
                                .addProxyRule(rule)
                                .build()
                            ProxyController.getInstance().setProxyOverride(
                                proxyConfig,
                                ContextCompat.getMainExecutor(this),
                                { result.success(true) }
                            )
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    } else {
                        result.success(false)
                    }
                }
                "clearProxyOverride" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        try {
                            ProxyController.getInstance().clearProxyOverride(
                                ContextCompat.getMainExecutor(this),
                                { result.success(true) }
                            )
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    } else {
                        result.success(false)
                    }
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

        // ──  系统 PiP 窗口动作通道 ──
        // Flutter 下发「播放/暂停、弹幕、快进」动作列表，原生构建 RemoteAction
        // 并刷新 PictureInPictureParams；PiP 窗口按钮点击经广播回传 Flutter。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PIP_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setActions" -> {
                    @Suppress("UNCHECKED_CAST")
                    val actions = call.argument<List<Map<String, Any?>>>("actions")
                    pipActions = buildPipActions(actions)
                    refreshPipParams()
                    result.success(true)
                }
                "clearActions" -> {
                    pipActions = emptyList()
                    refreshPipParams()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PIP_EVENTS
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    pipEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    pipEventSink = null
                }
            }
        )
        registerPipReceiver()
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

    /**
     * 应用内更新：通过 FileProvider 把 APK 安装包共享给系统安装器。
     * （Android 7+ 禁止隐式共享 file:// URI，必须使用 content:// URI。）
     */
    private fun installApk(apkFile: File) {
        val uri: Uri = FileProvider.getUriForFile(
            this,
            "com.nexhub.app.fileprovider",
            apkFile
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    /**
     * 把图片字节写入公共外部存储相册 Pictures/NexHub，返回对外可见路径。
     * Android 10+：MediaStore insert（IS_PENDING 两段式写入），分区存储免权限。
     * Android 9-：直写 Environment.DIRECTORY_PICTURES 并触发媒体扫描
     * （WRITE_EXTERNAL_STORAGE 已由 Dart 侧运行时申请）。
     */
    private fun saveImageToPublicPictures(bytes: ByteArray, fileName: String, mime: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, fileName)
                put(MediaStore.Images.Media.MIME_TYPE, mime)
                put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/NexHub")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val resolver = contentResolver
            val uri = resolver.insert(
                MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY),
                values
            ) ?: throw IllegalStateException("MediaStore insert failed")
            try {
                resolver.openOutputStream(uri)?.use { it.write(bytes) }
                    ?: throw IllegalStateException("openOutputStream failed")
                values.clear()
                values.put(MediaStore.Images.Media.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (e: Exception) {
                // 写入失败清理半成品占位记录，避免相册出现 0 字节幽灵图。
                runCatching { resolver.delete(uri, null, null) }
                throw e
            }
            return "Pictures/NexHub/$fileName"
        }
        @Suppress("DEPRECATION")
        val dir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
            "NexHub"
        )
        if (!dir.exists() && !dir.mkdirs()) {
            throw IllegalStateException("mkdirs failed: ${dir.path}")
        }
        val out = File(dir, fileName)
        out.writeBytes(bytes)
        MediaScannerConnection.scanFile(this, arrayOf(out.absolutePath), arrayOf(mime), null)
        return out.absolutePath
    }

    /**
     * MD3 触觉反馈：按语义模式播放官方触感原语（不依赖系统「触摸反馈」设置）。
     *
     * 优先级（Material 官方触感指南推荐顺序）：
     * 1. Android 12+（S）且电机支持组合原语 → `VibrationEffect.Composition`
     *    的 PRIMITIVE_TICK/CLICK/THUD（OEM 电机驱动调校，手感最佳）；
     * 2. Android 10+（Q）→ `createPredefined` 的官方预置效果
     *    （EFFECT_TICK/CLICK/HEAVY_CLICK/DOUBLE_CLICK）；
     * 3. Android 8-9 → 等幅单脉冲近似；8 以下退化为定时长震动。
     *
     * 模式对照（m3.material.io/foundations/designing-haptics）：
     * - tick：离散刻度/单选（滑块分档、分段按钮、导航项、chip）；
     * - click / toggleOn：点按确认、开关开启（开强关弱）；
     * - thunk：重按（长按开始、拖拽拿起、破坏性确认）；
     * - confirm：任务成功（上行双击）；reject：失败（下行重击）；
     * - gestureThreshold：手势越阈（下拉刷新触发）。
     */
    private fun vibrateEffect(effect: String) {
        val vibrator = obtainVibrator() ?: return
        // 每次先 cancel 清掉可能滞留的上一次波形：连续高频触感（开关/翻页/点按）
        // 时若不清理，部分 ROM 会把后续效果追加到已有队列，表现为「只有第一次
        // 有震动，之后再点没反应」。
        vibrator.cancel()
        when (effect) {
            "tick" ->
                if (!compose(vibrator, VibrationEffect.Composition.PRIMITIVE_TICK) {
                        it.addPrimitive(VibrationEffect.Composition.PRIMITIVE_TICK, 0.7f)
                    }
                ) predefinedOr(vibrator, VibrationEffect.EFFECT_TICK, 10, 150)
            "click", "toggleOn" ->
                if (!compose(vibrator, VibrationEffect.Composition.PRIMITIVE_CLICK) {
                        it.addPrimitive(VibrationEffect.Composition.PRIMITIVE_CLICK, 1.0f)
                    }
                ) predefinedOr(vibrator, VibrationEffect.EFFECT_CLICK, 18, 220)
            "toggleOff" ->
                if (!compose(vibrator, VibrationEffect.Composition.PRIMITIVE_TICK) {
                        it.addPrimitive(VibrationEffect.Composition.PRIMITIVE_TICK, 0.45f)
                    }
                ) predefinedOr(vibrator, VibrationEffect.EFFECT_TICK, 8, 120)
            "thunk" ->
                if (!compose(vibrator, VibrationEffect.Composition.PRIMITIVE_THUD) {
                        it.addPrimitive(VibrationEffect.Composition.PRIMITIVE_THUD, 1.0f)
                    }
                ) predefinedOr(vibrator, VibrationEffect.EFFECT_HEAVY_CLICK, 35, 255)
            "confirm" ->
                if (!compose(vibrator, VibrationEffect.Composition.PRIMITIVE_TICK, VibrationEffect.Composition.PRIMITIVE_CLICK) {
                        it.addPrimitive(VibrationEffect.Composition.PRIMITIVE_TICK, 0.6f)
                            .addPrimitive(VibrationEffect.Composition.PRIMITIVE_CLICK, 1.0f, 70)
                    }
                ) predefinedOr(
                    vibrator, VibrationEffect.EFFECT_DOUBLE_CLICK, 0, 0,
                    waveform = longArrayOf(0, 25, 60, 25), amps = intArrayOf(0, 180, 0, 255)
                )
            "reject" ->
                if (!compose(vibrator, VibrationEffect.Composition.PRIMITIVE_THUD, VibrationEffect.Composition.PRIMITIVE_TICK) {
                        it.addPrimitive(VibrationEffect.Composition.PRIMITIVE_THUD, 1.0f)
                            .addPrimitive(VibrationEffect.Composition.PRIMITIVE_TICK, 0.5f, 70)
                    }
                ) predefinedOr(
                    vibrator, null, 0, 0,
                    waveform = longArrayOf(0, 30, 70, 25), amps = intArrayOf(0, 255, 0, 140)
                )
            "gestureThreshold" ->
                if (!compose(vibrator, VibrationEffect.Composition.PRIMITIVE_TICK) {
                        it.addPrimitive(VibrationEffect.Composition.PRIMITIVE_TICK, 1.0f)
                    }
                ) predefinedOr(vibrator, VibrationEffect.EFFECT_TICK, 12, 200)
            else ->
                if (!compose(vibrator, VibrationEffect.Composition.PRIMITIVE_CLICK) {
                        it.addPrimitive(VibrationEffect.Composition.PRIMITIVE_CLICK, 1.0f)
                    }
                ) predefinedOr(vibrator, VibrationEffect.EFFECT_CLICK, 18, 220)
        }
    }

    /** 取系统振动器（S+ 走 VibratorManager，旧版本走已废弃的 VibratorService）。 */
    private fun obtainVibrator(): Vibrator? {
        val v: Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)
                ?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
        return if (v != null && v.hasVibrator()) v else null
    }

    /** S+ 且电机支持给定组合原语时按 [block] 组合播放；否则返回 false 走降级。 */
    private fun compose(
        vibrator: Vibrator,
        vararg primitives: Int,
        block: (VibrationEffect.Composition) -> Unit
    ): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        return try {
            if (!vibrator.areAllPrimitivesSupported(*primitives)) return false
            val composition = VibrationEffect.startComposition()
            block(composition)
            vibrator.vibrate(composition.compose())
            true
        } catch (_: Exception) {
            false
        }
    }

    /**
     * 组合原语降级路径：Q+ 播放官方预置效果 [effectId]（[waveform] 双脉冲
     * 模式优先用波形以区分上行/下行手感）；26-28 用振幅波形/单脉冲近似；
     * 8 以下退化为定时长震动。
     */
    private fun predefinedOr(
        vibrator: Vibrator,
        effectId: Int?,
        ms: Int,
        amp: Int,
        waveform: LongArray? = null,
        amps: IntArray? = null
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            effectId != null && waveform == null
        ) {
            vibrator.vibrate(VibrationEffect.createPredefined(effectId))
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            waveform != null && amps != null
        ) {
            vibrator.vibrate(VibrationEffect.createWaveform(waveform, amps, -1))
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && ms > 0) {
            vibrator.vibrate(VibrationEffect.createOneShot(ms.toLong(), amp))
            return
        }
        @Suppress("DEPRECATION")
        if (waveform != null) {
            vibrator.vibrate(waveform, -1)
        } else {
            vibrator.vibrate(maxOf(ms, 10).toLong())
        }
    }

    // ──  系统 PiP 窗口动作（Android O+）──────────────────────────────

    companion object {
        private const val PIP_CHANNEL = "nexhub/pip"
        private const val PIP_EVENTS = "nexhub/pip_events"
        private const val HAPTIC_CHANNEL = "nexhub/haptic"
        private const val PIP_ACTION = "com.nexhub.app.PIP_ACTION"
        private const val EXTRA_ACTION_ID = "actionId"
        // PendingIntent 请求码基址：每个动作 +index，保持稳定复用（FLAG_UPDATE_CURRENT）。
        private const val PIP_ACTION_REQUEST_BASE = 2000
    }

    /** 注册 PiP 动作广播接收器（幂等：重复注册会抛异常，用标志位防重）。 */
    private fun registerPipReceiver() {
        if (pipReceiverRegistered) return
        pipReceiverRegistered = true
        val filter = IntentFilter(PIP_ACTION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(pipActionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(pipActionReceiver, filter)
        }
    }

    /**
     * 把 Flutter 下发的动作列表构建成 [RemoteAction]。
     * 图标按字符串图标名映射到应用 drawable；Android O 以下不支持 RemoteAction，
     * 返回空列表（PiP 无窗口动作，仅系统默认行为）。
     */
    private fun buildPipActions(actions: List<Map<String, Any?>>?): List<RemoteAction> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || actions.isNullOrEmpty()) {
            return emptyList()
        }
        return actions.mapIndexedNotNull { index, map ->
            val id = map["id"] as? String ?: return@mapIndexedNotNull null
            val title = (map["title"] as? String) ?: id
            val icon = when (map["icon"]) {
                "pause" -> R.drawable.ic_pip_pause
                "rewind" -> R.drawable.ic_pip_rewind
                "forward" -> R.drawable.ic_pip_forward
                else -> R.drawable.ic_pip_play
            }
            val intent = Intent(PIP_ACTION).apply {
                setPackage(packageName)
                putExtra(EXTRA_ACTION_ID, id)
            }
            val pending = PendingIntent.getBroadcast(
                this,
                PIP_ACTION_REQUEST_BASE + index,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            RemoteAction(Icon.createWithResource(this, icon), title, title, pending)
        }
    }

    /** 用当前动作列表刷新 PictureInPictureParams（进入 PiP 前或状态变化时调用）。 */
    private fun refreshPipParams() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            val builder = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(16, 9))
            if (pipActions.isNotEmpty()) {
                builder.setActions(pipActions)
            }
            setPictureInPictureParams(builder.build())
        } catch (_: Exception) {
            // 低版本 / 参数非法时忽略：PiP 基础进出仍可用。
        }
    }

    /**
     * PiP 进出事件推送 + 动作参数恢复。
     *
     * 1. 经 `nexhub/pip_events` 向 Flutter 推送 `pip:enabled` / `pip:disabled`。
     *    floating 包的 pipStatusStream 实际以 10ms 间隔轮询平台通道且定时器
     *    永不停止（首次使用后整个进程持续每秒 ~100 次原生调用，在 PiP 视频
     *    解码场景会把系统拖到严重卡顿）——因此 Dart 侧彻底不用它，进出事件
     *    全部由本回调推送，零轮询。
     * 2. 进入 PiP 后延迟 250ms 重放动作参数：floating 经
     *    enterPictureInPictureMode(builder.build()) 进入时传入的 params 只含
     *    宽高比、不含动作列表，会顶掉此前 setPictureInPictureParams 下发的
     *    RemoteActions；转场动画中同步重放又会与系统转场互相干扰，故延后。
     */
    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        mainHandler.removeCallbacks(pipRefreshRunnable)
        if (isInPictureInPictureMode) {
            pipEventSink?.success("pip:enabled")
            mainHandler.postDelayed(pipRefreshRunnable, 250)
        } else {
            pipEventSink?.success("pip:disabled")
        }
    }

    override fun onDestroy() {
        mainHandler.removeCallbacks(pipRefreshRunnable)
        if (pipReceiverRegistered) {
            try {
                unregisterReceiver(pipActionReceiver)
            } catch (_: Exception) {
                // 忽略：Activity 生命周期抖动时可能已注销。
            }
            pipReceiverRegistered = false
        }
        super.onDestroy()
    }
}
