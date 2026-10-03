package com.nexhub.app

import android.content.Context
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Bangumi ECH 本地代理的 Android 侧桥接。
 *
 * 移植自参考项目 Bangumi-master 的
 * `android/app/src/main/java/com/czy0729/bangumi/doh/EchProxyModule.java`
 * （React Native `ReactContextBaseJavaModule`，255 行），把其「静态端口 + 日志环形
 * 缓冲 + enable/disable/getStatus/getLogs 状态机」原样搬到 Flutter 的
 * [MethodChannel] `nexhub/ech_proxy` 上。
 *
 * Dart 对端：`lib/core/services/bangumi/bangumi_ech_proxy.dart`
 * （方法 `enable{port,dns}` → Int / `disable` / `getStatus` → {running,port} /
 * `getLogs` → [{time,level,type,message}] / `setScope{targets,echConfigList,allowAnyHost}`）。
 *
 * ## 与参考实现的差异（均为「参考项目有、NexHub 无对应组件」，非能力删减）
 * - 参考在 enable 成功后调 `DoHDNS.getInstance().setEchProxy(cacheDir)` 共享缓存：
 *   NexHub 的 DNS 解析在 Dart 侧（`lib/core/network/runtime/dns_resolver.dart`）
 *   独立实现，无 Java 侧 DoH 组件，故 N/A。
 * - 参考调 `evictOkHttpConnectionPool()` 踢掉残留死连接：NexHub 的 Dart 流量走
 *   `dart:io` HttpClient 而非 OkHttp，Java 侧无连接池可踢，故 N/A。
 * - 参考的 `setOkHttpProxy` / `clearOkHttpProxy` 本身已是 no-op（路由改由
 *   ProxySelector 白名单实现），NexHub 不需要这两个方法，不再保留。
 *
 * 其余语义（含「静态端口防重复启动」「getStatus 真实存活检测并复位」）
 * 与参考逐条对齐。
 */
object EchProxyBridge {
    private const val TAG = "NexHubEch"
    private const val MAX_LOGS = 50
    private const val DEFAULT_DNS = "https://cloudflare-dns.com/dns-query"

    /** 日志时间格式与参考一致（HH:mm:ss）。 */
    private val timeFormat = SimpleDateFormat("HH:mm:ss", Locale.getDefault())

    private class LogEntry(
        val time: Long,
        val level: String,
        val type: String,
        val message: String,
    )

    /**
     * 当前代理端口，0 表示未运行。
     *
     * 刻意做成**进程级静态**（对应参考 `static volatile int sProxyPort`）：
     * Activity / FlutterEngine 重建后仍以它为准，避免「原生代理还在跑，新实例
     * 又启动一个」的端口泄漏。
     */
    @Volatile
    private var proxyPort: Int = 0

    private val logs = ArrayList<LogEntry>()
    private val logsLock = Any()

    /** 日志上限与参考一致（50 条，超出丢最旧）。 */
    fun addLog(level: String, message: String) = addLog(level, "proxy", message)

    fun addLog(level: String, type: String, message: String) {
        synchronized(logsLock) {
            if (logs.size >= MAX_LOGS) logs.removeAt(0)
            logs.add(
                LogEntry(
                    time = System.currentTimeMillis(),
                    level = level,
                    type = type,
                    message = message,
                )
            )
        }
    }

    /** 供其他原生组件读取当前端口（对应参考 `getProxyPort`）。 */
    fun getProxyPort(): Int = proxyPort

    /**
     * 统一处理 `nexhub/ech_proxy` 的方法调用。
     *
     * [Context] 用于取 `filesDir`（放自签 CA，需持久）与 `cacheDir`（放 ECH 缓存，
     * 可丢），与参考的 `getFilesDir()` / `getCacheDir()` 一致。
     */
    fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "enable" -> {
                val port = call.argument<Int>("port") ?: 0
                val dns = call.argument<String>("dns") ?: DEFAULT_DNS
                enable(
                    context = context,
                    port = port,
                    dns = dns,
                    targets = call.argument<String>("targets") ?: "",
                    echConfigList = call.argument<String>("echConfigList") ?: "",
                    allowAnyHost = call.argument<Boolean>("allowAnyHost") ?: false,
                    verboseLog = call.argument<Boolean>("verboseLog") ?: false,
                    result = result,
                )
            }
            "setScope" -> {
                applyScope(
                    targets = call.argument<String>("targets") ?: "",
                    echConfigList = call.argument<String>("echConfigList") ?: "",
                    allowAnyHost = call.argument<Boolean>("allowAnyHost") ?: false,
                    verboseLog = call.argument<Boolean>("verboseLog") ?: false,
                )
                result.success(null)
            }
            "disable" -> disable(result)
            "getStatus" -> getStatus(result)
            "getLogs" -> getLogs(result)
            else -> result.notImplemented()
        }
    }

    /**
     * 下发 ECH 接管作用域（NexHub 扩展；参考项目把域名写死在编译期常量里）。
     *
     * 与 `enable` 分开是**刻意**的：`enable` 在 `proxyPort > 0` 时会提前返回（防重复起服务），
     * 若作用域只经 `enable` 下发，就会出现「代理已在跑、用户改了设置却不生效」。
     * native 侧把作用域存在自有静态里，故**启动前**和**运行中**都可以调用。
     */
    private fun applyScope(
        targets: String,
        echConfigList: String,
        allowAnyHost: Boolean,
        verboseLog: Boolean,
    ) {
        EchProxyNative.safeSetScope(targets, echConfigList, allowAnyHost, verboseLog)
        val desc = when {
            allowAnyHost -> "任意域（不适合 ECH 的域逐域回退直连）"
            targets.isNotBlank() -> "白名单 $targets + 内置 Bangumi 域"
            else -> "仅内置 Bangumi 域"
        }
        val eclDesc = if (echConfigList.isBlank()) "GREASE 探测" else "用户自备 ECHConfigList"
        addLog("info", "scope", "接管作用域: $desc / $eclDesc")
    }

    /**
     * 启动代理（对应参考 `enable`）。
     *
     * 放后台线程执行：`startProxy` 会生成自签 CA、绑定 listener 并起线程，可能耗时；
     * MethodChannel 回调默认在平台主线程，直接跑有 ANR 风险（与 `nexhub/media_store`
     * 的 `saveImage` 同样处理——该通道也是在工作线程里回调 `result`）。
     */
    private fun enable(
        context: Context,
        port: Int,
        dns: String,
        targets: String,
        echConfigList: String,
        allowAnyHost: Boolean,
        verboseLog: Boolean,
        result: MethodChannel.Result,
    ) {
        if (!EchProxyNative.isAvailable) {
            result.error(
                "ECH_NATIVE_UNAVAILABLE",
                "Native library libechproxy.so not available",
                null
            )
            return
        }

        // 作用域必须在 startProxy **之前**下发：native 侧据此决定启动时预热哪些域。
        applyScope(targets, echConfigList, allowAnyHost, verboseLog)

        // 以静态 proxyPort 为准，防止 Activity/引擎重建后重复启动。
        if (proxyPort > 0) {
            addLog("info", "proxy", "代理已在运行，端口: $proxyPort")
            // 代理仍在运行，不清理任何连接资源——避免误杀健康连接。
            // 作用域已在上方热更新，用户改完设置立即生效，无需重启代理。
            result.success(proxyPort)
            return
        }

        Thread {
            try {
                val caDir = context.filesDir.absolutePath
                val cacheDir = context.cacheDir.absolutePath
                Log.d(TAG, "Starting proxy with port=$port, dns=$dns, caDir=$caDir, cacheDir=$cacheDir")
                addLog("info", "proxy", "启动代理中，端口: " + if (port == 0) "随机" else port.toString())
                addLog("info", "dns", "DoH 服务器: $dns")

                val started = EchProxyNative.safeStartProxy(port, dns, caDir, cacheDir)
                if (started <= 0) {
                    Log.e(TAG, "Proxy failed to start: returned port $started")
                    addLog("error", "proxy", "启动失败，端口返回 0")
                    result.error("ECH_START_FAILED", "Proxy failed to start (port=$started)", null)
                    return@Thread
                }

                proxyPort = started
                Log.d(TAG, "Proxy started: port=$started")
                addLog("success", "proxy", "代理已启动，端口: $started")
                result.success(started)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start proxy", e)
                addLog("error", "proxy", "启动异常: ${e.message}")
                // 失败时复位状态，避免残留「以为在跑」的端口。
                proxyPort = 0
                result.error("ECH_START_FAILED", e.message, null)
            }
        }.start()
    }

    /**
     * 停止代理（对应参考 `disable`）。
     *
     * 不依赖「是否在运行」的前置判断，总是尝试停 native server（幂等），
     * 与参考一致——参考注释明确「不依赖实例 running 字段」。
     */
    private fun disable(result: MethodChannel.Result) {
        Thread {
            try {
                addLog("info", "proxy", "停止代理中...")
                EchProxyNative.safeStopProxy()
                proxyPort = 0
                addLog("success", "proxy", "代理已停止")
                result.success(null)
            } catch (e: Exception) {
                addLog("error", "proxy", "停止失败: ${e.message}")
                result.error("ECH_STOP_FAILED", e.message, null)
            }
        }.start()
    }

    /**
     * 上报状态（对应参考 `getStatus`）。
     *
     * **真实存活检测**：不仅看静态端口，还问 native listener 线程是否存活；
     * 已死但 Java 侧标志未同步时复位端口，让 Dart 侧的状态机据此重建。
     */
    private fun getStatus(result: MethodChannel.Result) {
        val alive = EchProxyNative.safeIsAlive()
        if (!alive && proxyPort > 0) {
            Log.d(TAG, "getStatus: native proxy dead, resetting proxyPort")
            addLog("warn", "proxy", "检测到代理已停止, 重置状态")
            proxyPort = 0
        }
        result.success(
            mapOf(
                "running" to (proxyPort > 0),
                "port" to proxyPort,
            )
        )
    }

    /** 返回日志快照（对应参考 `getLogs`；时间戳为毫秒 epoch，Dart 侧读 int）。 */
    private fun getLogs(result: MethodChannel.Result) {
        val out = ArrayList<Map<String, Any>>()
        synchronized(logsLock) {
            for (entry in logs) {
                out.add(
                    mapOf(
                        "time" to entry.time,
                        "level" to entry.level,
                        "type" to entry.type,
                        "message" to entry.message,
                    )
                )
            }
        }
        result.success(out)
    }

    /** 预留：把日志按参考格式格式化为 `HH:mm:ss` 文本（调试面板用）。 */
    @Suppress("unused")
    private fun formatTime(time: Long): String = timeFormat.format(Date(time))
}
