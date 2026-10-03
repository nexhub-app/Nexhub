package com.nexhub.app

import android.util.Log

/**
 * ECH 原生库（`libechproxy.so`）的 JNI 入口。
 *
 * 移植自参考项目 Bangumi-master 的
 * `android/app/src/main/java/com/czy0729/bangumi/doh/EchProxyNative.java`
 * （React Native 版 `public static native`），改为 Kotlin `object`。
 *
 * ## JNI 符号契约（改包名/类名必须同步改 Rust 侧，否则 `loadLibrary` 后调用即崩）
 * JNI 符号名由「声明 native 方法的类的全限定名」决定：
 * `com.nexhub.app.EchProxyNative` → `Java_com_nexhub_app_EchProxyNative_*`，
 * 与 `android/rust/src/lib.rs` 的 `pub mod android` 逐一对应
 * （`startProxy` / `stopProxy` / `getCaPem` / `isAlive` / `setScope`）。
 *
 * 用 `object`（而非 `companion object`）是刻意的：Kotlin `companion object` 会把
 * 成员编译进 `EchProxyNative$Companion`，JNI 符号变成
 * `Java_com_nexhub_app_EchProxyNative_00024Companion_*`，与 Rust 侧不匹配。
 * Kotlin `object` 的 `external fun` 编译为单例类上的实例 native 方法，符号正是
 * `Java_com_nexhub_app_EchProxyNative_<name>` ✅（JNI 符号名不区分静态/实例，
 * Rust 侧第 2 个参数声明为 `JClass` 但实际是 `jobject`，二者同为裸指针、ABI 等价）。
 *
 * 注意：native 方法**不可**声明为 `internal`——Kotlin 会给 `internal` 成员加
 * `$模块名` 后缀混淆，符号名随之改变。
 */
object EchProxyNative {
    private const val TAG = "NexHubEch"

    /** native library 是否加载成功（对应参考 `EchProxyNative.isAvailable`）。 */
    @Volatile
    var isAvailable: Boolean = false
        private set

    init {
        // 只在首次访问本 object 时执行一次。
        try {
            System.loadLibrary("echproxy")
            isAvailable = true
            Log.d(TAG, "libechproxy.so loaded successfully")
            EchProxyBridge.addLog("success", "proxy", "ECH 原生库加载成功")
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to load libechproxy.so", t)
            isAvailable = false
            EchProxyBridge.addLog("error", "proxy", "ECH 原生库加载失败: ${t.message}")
        }
    }

    /**
     * 安全调用 [startProxy]：native 不可用时返回 0。
     *
     * 返回 >0 为实际监听端口（传 0 表示由 native 分配随机端口）；<=0 为失败。
     */
    fun safeStartProxy(port: Int, dns: String, caDir: String, cacheDir: String): Int {
        if (!isAvailable) {
            Log.e(TAG, "startProxy called but native library not available")
            return 0
        }
        return try {
            startProxy(port, dns, caDir, cacheDir)
        } catch (t: Throwable) {
            Log.e(TAG, "startProxy failed", t)
            0
        }
    }

    /** 安全调用 [stopProxy]。 */
    fun safeStopProxy() {
        if (!isAvailable) {
            Log.e(TAG, "stopProxy called but native library not available")
            return
        }
        try {
            stopProxy()
        } catch (t: Throwable) {
            Log.e(TAG, "stopProxy failed", t)
        }
    }

    /** 安全调用 [getCaPem]；native 不可用时返回 null。 */
    fun safeGetCaPem(): String? {
        if (!isAvailable) {
            Log.e(TAG, "getCaPem called but native library not available")
            return null
        }
        return try {
            getCaPem()
        } catch (t: Throwable) {
            Log.e(TAG, "getCaPem failed", t)
            null
        }
    }

    /** 安全调用 [isAlive]，检测代理 listener 线程是否真实存活。 */
    fun safeIsAlive(): Boolean {
        if (!isAvailable) return false
        return try {
            isAlive()
        } catch (t: Throwable) {
            Log.e(TAG, "isAlive failed", t)
            false
        }
    }

    /** 安全调用 [setScope]（native 不可用时静默跳过，作用域会在下次可用时由上层重下发）。 */
    fun safeSetScope(
        targetsCsv: String,
        echConfigListB64: String,
        allowAnyHost: Boolean,
        verboseLog: Boolean,
    ) {
        if (!isAvailable) {
            Log.e(TAG, "setScope called but native library not available")
            return
        }
        try {
            setScope(targetsCsv, echConfigListB64, allowAnyHost, verboseLog)
        } catch (t: Throwable) {
            Log.e(TAG, "setScope failed", t)
        }
    }

    // ── native 声明（符号名必须与 android/rust/src/lib.rs 的 pub mod android 一致）──

    /** 启动本地 ECH 代理，返回监听端口（<=0 表示失败）。 */
    external fun startProxy(port: Int, dns: String, caDir: String, cacheDir: String): Int

    /** 停止本地 ECH 代理（幂等）。 */
    external fun stopProxy()

    /** 取自签 MITM CA 的 PEM（当前 Dart 侧未使用：全局 HttpClient 已无条件容忍自签证书）。 */
    external fun getCaPem(): String

    /** listener 线程是否真实存活（用于识别「Java 标志还在但 native 已死」）。 */
    external fun isAlive(): Boolean

    /**
     * 下发运行期 ECH 接管作用域（NexHub 扩展；参考项目把域名写死在编译期常量里）。
     *
     * @param targetsCsv 额外接管的域名，英文逗号分隔；空串表示只接管 native 内置的
     *   Bangumi 域（`bgm.tv` / `chii.in` 及其子域）。
     * @param echConfigListB64 用户自备 ECHConfigList（标准 base64）；空串表示走 GREASE 探测。
     * @param allowAnyHost 是否接管任意域（应用级 / 源级接管打开时为 true）。
     * @param verboseLog 是否打开 native 侧 debug 日志。native 库**恒定以 release 编译**，
     *   参考实现里 `#[cfg(debug_assertions)]` 的 debug 日志在本项目永远是死代码，
     *   故改为运行期开关 —— Flutter 侧只在 debug 构建下打开它。
     *
     * 可以**在 [startProxy] 之前**调用（先定作用域再起服务，预热范围随之变化），
     * 也可以在代理运行中调用以热更新。native 侧存在自有静态里，启动/停止都不会丢。
     */
    external fun setScope(
        targetsCsv: String,
        echConfigListB64: String,
        allowAnyHost: Boolean,
        verboseLog: Boolean,
    )
}
