import java.util.Properties
import java.io.FileInputStream

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
// 注意：archivesBaseName 是 project 级属性，Kotlin DSL 中不能在 defaultConfig 内直接赋值，
// 必须用 project.setProperty 在顶层设置（Groovy DSL 才允许写在 defaultConfig 里）。
project.setProperty("archivesBaseName", "NexHub")

android {
    namespace = "com.nexhub.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
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
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                // 无签名凭据（如 fork 的 PR 构建）：回落 debug 签名，保证可编译。
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
