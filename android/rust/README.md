# ECH Proxy - 原生引擎（Android JNI + 桌面 C API）

本地 HTTPS CONNECT 代理，通过 ECH (Encrypted Client Hello) + DoH 绕过 SNI 封锁。
同一份 Rust 源码编译出两种接入形态：

- **Android**：`libechproxy.so` → JNI（`com.nexhub.app.EchProxyNative`）→
  `MethodChannel('nexhub/ech_proxy')`
- **桌面 (Windows/Linux/macOS)**：`echproxy.dll` / `libechproxy.so` /
  `libechproxy.dylib` → dart:ffi 直接绑定 C API（`ech_*`，见 `src/lib.rs` 末尾）

## 架构

```
Dart BangumiEchProxy (lib/core/services/bangumi/bangumi_ech_proxy.dart)
  ├─ Android:  MethodChannel → EchProxyBridge (Kotlin) → JNI → Rust
  └─ 桌面:     dart:ffi → ech_start_proxy / ech_set_scope / ... → Rust
      Rust libechproxy
        ├── 本地 HTTP CONNECT 代理
        ├── ECH TLS 后端 (OpenSSL 4.0.1 + ech.h)
        ├── MITM: 自签 CA → per-host 证书 → rustls
        └── DoH DNS 解析
```

## 依赖

| 依赖        | 版本          | 说明                            |
| ----------- | ------------- | ------------------------------- |
| Rust        | stable        | target 见下方 ABI 表 / 桌面 host |
| cargo-ndk   | latest        | Android NDK 集成（仅 Android）   |
| OpenSSL     | 4.0.1         | 需要 ECH 支持 (`openssl/ech.h`) |
| Android NDK | 27.0.12077973 | 在 `build-android.sh` 中配置    |
| Visual Studio | 含 VC 工具链 | 仅 Windows 桌面构建（cl/nmake/dumpbin） |
| Strawberry Perl | 5.42 portable | 仅 Windows：OpenSSL 拒绝 cygwin perl，脚本自动下载 |

## 构建

### Android（三 ABI：arm64-v8a / armeabi-v7a / x86_64）

```bash
bash build-android.sh            # 全量三个 ABI
bash build-android.sh arm64-v8a  # 单个 ABI
```

脚本会自动检查 OpenSSL 源码是否存在（不存在则自动多源下载，也可手动放到
`openssl/build/openssl-4.0.1/`）。产物按 ABI 独立：

```
android/app/src/main/jniLibs/<abi>/libechproxy.so
android/rust/openssl/install-<abi>/        ← OpenSSL 静态库（gitignored）
android/rust/target/                       ← Cargo 产物（gitignored）
```

| jniLibs 目录  | Rust target             | OpenSSL Configure target |
| ------------- | ----------------------- | ------------------------ |
| arm64-v8a     | aarch64-linux-android   | android-arm64            |
| armeabi-v7a   | armv7-linux-androideabi | android-arm              |
| x86_64        | x86_64-linux-android    | android-x86_64           |

注意：APK 体积按打包进来的 ABI 数线性增长（每个 .so 约 7-9.5MB）。只发某
渠道时可删掉多余 jniLibs 目录或配 gradle `abiFilters`；缺失 ABI 的设备上
`System.loadLibrary` 失败会被 Kotlin 侧捕获，ECH 安全降级为直连。

### Windows 桌面（echproxy.dll）

```bash
bash build-windows.sh
```

流程：自动定位 `vcvars64.bat`（vswhere）→ 自动下载原生 perl（Strawberry
portable）与 NASM（若 PATH 没有）→ `VC-WIN64A` 静态编译 OpenSSL（带 ECH）→
`cargo build --release --target x86_64-pc-windows-msvc`（+crt-static，
DLL 不依赖 VC++ 运行库）→ 产物复制到 `windows/dll/`。

`flutter run -d windows` / `flutter build windows` 会经
`windows/CMakeLists.txt` 的 POST_BUILD 规则把 `echproxy.dll` 复制到 exe 目录，
Dart 侧 `DynamicLibrary.open('echproxy.dll')` 即可解析。

### Linux / macOS 桌面

Dart FFI 后端按标准名字加载（缺库时安全降级，不影响其他功能）：

- Linux：`libechproxy.so`（放进 `build/linux/x64/release/bundle/lib/`）
- macOS：`libechproxy.dylib`（放进 `*.app/Contents/Frameworks/`，Runner 的
  rpath `@executable_path/../Frameworks` 可解析）

构建脚本可仿照 `build-windows.sh`：Linux 用 `linux-x86_64` Configure 目标 +
宿主 gcc/clang；macOS 用 `darwin64-arm64-cc` / `darwin64-x86_64-cc` +
`--target aarch64-apple-darwin`。

### iOS

未支持：需要把 Rust 产物作为静态库链接进 Xcode 工程（podspec/vndk），待后续。

## 源码

| 文件              | 作用                                        |
| ----------------- | ------------------------------------------- |
| `src/lib.rs`      | 代理主逻辑、JNI 入口（android 门控）、C API（`ech_*`）、ECH 后端、MITM、DNS |
| `ech_helper.c`    | OpenSSL ECH GREASE retry-config 获取        |
| `build.rs`        | 编译期探测 `openssl/ech.h`                  |
| `Cargo.toml`      | Rust 依赖（`jni` 仅 Android target 依赖）   |
| `build-android.sh`| Android 三 ABI 构建                         |
| `build-windows.sh`| Windows 桌面构建                            |

## 注意事项

- OpenSSL 必须有 ECH 支持 (`ech.h`)，否则编译为 `no_ech` 版本，ECH 功能不可用
- OpenSSL 4.0 的 Configure 对 `-static` 会隐式 `no-threads`，构建脚本带产物
  自检（`CRYPTO_THREAD_write_lock` 符号），no-threads 构建会直接失败退出
- Windows 构建链路全部幂等可重跑：perl/NASM/OpenSSL 均缓存于 `.build/`、
  `openssl/install-win64/`，重跑只做增量
