allprojects {
    repositories {
        // 官方仓库优先（CI runner 直连 Google/Maven Central 稳定），阿里云镜像作为兜底。
        google()
        mavenCentral()
        maven { setUrl("https://maven.aliyun.com/repository/google") }
        maven { setUrl("https://maven.aliyun.com/repository/central") }
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// 统一插件子项目的 compileSdk：部分 pub 插件仍写死 31~34，AGP 9 的 AAR 元数据
// 校验会因依赖要求 compileSdk >= 36 而直接失败（如 :file_picker）。
// app 模块已在 app/build.gradle.kts 里显式设为 36；它因 evaluationDependsOn
// 被提前求值，不能再挂 afterEvaluate，直接跳过。
subprojects {
    if (name != "app" && !state.executed) {
        afterEvaluate {
            (extensions.findByName("android") as? com.android.build.gradle.BaseExtension)?.let {
                it.compileSdkVersion(36)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
