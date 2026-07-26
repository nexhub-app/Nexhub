plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
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

    // 固定签名 keystore（提交入库，保证每次 CI 构建签名一致，可覆盖安装）。
    // 警告：此 keystore 随公开仓库公开，仅用于测试分发，请勿用于 Google Play 正式上架。
    // 如需正式上架，请改用 GitHub Actions secret 注入私有 release keystore。
    signingConfigs {
        create("release") {
            keyAlias = "nexhub"
            keyPassword = "***REMOVED***"
            storeFile = file("upload-keystore.jks")
            storePassword = "***REMOVED***"
            storeType = "PKCS12"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}
