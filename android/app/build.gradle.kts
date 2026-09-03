import java.util.Properties
import java.io.FileInputStream
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 签名信息从 android/key.properties 读取（该文件已 gitignore，不入库）。
// 本地打包：在 android/key.properties 中填写密码（模板见 key.properties.example）。
// CI 打包：workflow 在构建前从 GitHub Secrets 生成该文件与 keystore。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// 让产出的 APK 文件名前缀为软件名（NexHub-arm64-v8a-release.apk 而非 app-*.apk）。
// 注意：Gradle 9 移除了 project 级 archivesBaseName 属性，改用 base.archivesName。
base { archivesName.set("NexHub") }

android {
    namespace = "com.nexhub.app"
    // 覆盖 Flutter 默认（35 / 26.3）：flutter_tts、media_kit_* 等多个插件要求
    // compileSdk 36 + ndk 27（flutter build 已明确告警）。需本机已安装
    // Android SDK Platform 36 与 NDK 27.0.12077973（SDK Manager 安装）。
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications 的 AAR 元数据要求 app 启用 core library desugaring
        // （checkReleaseAarMetadata 会直接 FAILURE），否则构建报
        // "requires core library desugaring to be enabled for :app"。
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.nexhub.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // super_clipboard（复制图片）要求 minSdk >= 23；flutter_tts 要求 minSdk >= 24。
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 签名 keystore：文件与密码均不入库（keystore 被 gitignore，密码在 key.properties）。
    // 本地/CI 均通过 key.properties 提供凭据；缺失时回落 debug 签名（仅供本地调试，
    // 产出的 release 包无法覆盖安装正式签名版本）。
    // 注意：storeFile 必须以 rootProject（android/）为基准解析相对路径，
    // 不能用 file("upload-keystore.jks") —— 在 signingConfigs 嵌套作用域里它常被解析到
    // 根工程目录 android/ 而非 android/app，导致 validateSigningRelease 找不到 keystore。
    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = (keystoreProperties["storeFile"] as String?)?.let {
                rootProject.file(it)
            }
            storePassword = keystoreProperties["storePassword"] as String?
            storeType = "PKCS12"
        }
    }

    buildTypes {
        release {
            // 显式关闭 R8/资源压缩：避免任何混淆或裁切影响 flutter_inappwebview
            // 等插件的运行时行为（也确保 assets/sniffer/* 等资源不被误删）。
            isMinifyEnabled = false
            isShrinkResources = false
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                // 无签名凭据（如 fork 的 PR 构建）：回落 debug 签名，保证可编译。
                signingConfigs.getByName("debug")
            }
        }
    }
}

// AGP 9 / Kotlin 2.3 起 kotlinOptions{ jvmTarget } 弃用（编译错误级），改用 compilerOptions DSL。
kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}

// 源 WebView 网络跟随：ProxyController（API 28+）把源域名导到本地正向代理，
// 绕开 DNS 污染。androidx.webkit 提供 ProxyConfig / ProxyController。
dependencies {
    // 上面 isCoreLibraryDesugaringEnabled 所需的 desugar 运行时库
    // （版本需 >= flutter_local_notifications 元数据要求的最低值，2.1.5 满足）。
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    implementation("androidx.webkit:webkit:1.12.0")
}
