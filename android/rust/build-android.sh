#!/bin/bash
set -e

# ============================================================
# ECH Proxy - Android 交叉编译脚本
#
# 用法:
#   ./build-android.sh            # 全量编译三个 ABI 并输出到 jniLibs/<abi>/
#   ./build-android.sh arm64-v8a  # 只编译单个 ABI (armeabi-v7a / x86_64 同理)
#   ./build-android.sh --setup    # 仅准备工具链 (Rust target / cargo-ndk / NDK / perl 模块)
#
# 环境要求:
#   - Linux / macOS: 开箱可用
#   - Windows: 用 Git for Windows 自带的 Git-Bash 运行
#     (bash / perl / nproc / curl / tar 均已随 Git for Windows 提供)
#     例: "D:\Git\bin\bash.exe" -lc 'bash /e/nexhub/android/rust/build-android.sh'
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
JNILIBS_ROOT="$PROJECT_ROOT/android/app/src/main/jniLibs"
NDK_VERSION="27.0.12077973"
OPENSSL_VERSION="4.0.1"

# 要构建的 ABI 清单（与 Flutter 官方支持面一致；x86 32 位模拟器不再提供）
#   jniLibs 目录        Rust target              OpenSSL Configure target
#   arm64-v8a           aarch64-linux-android    android-arm64
#   armeabi-v7a         armv7-linux-androideabi  android-arm
#   x86_64              x86_64-linux-android     android-x86_64
ABIS=(
    "arm64-v8a aarch64-linux-android android-arm64"
    "armeabi-v7a armv7-linux-androideabi android-arm"
    "x86_64 x86_64-linux-android android-x86_64"
)

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[build]${NC} $1"; }
warn() { echo -e "${YELLOW}[warn]${NC} $1"; }
err() { echo -e "${RED}[error]${NC} $1"; exit 1; }

# ============================================================
# 主机环境适配 (Windows / Git for Windows)
#
# 原参考实现只面向 macOS, 在 Windows 上需要三处适配:
#
# 1) 路径风格 —— Configurations/15-android.conf 用字符串前缀匹配判断编译器是否来自 NDK:
#      if (which("clang") =~ m|^$ndk/.*/prebuilt/([^/]+)/|) { ... }
#      else { ... die "no NDK $triarch-gcc on \$PATH" }      # 见 15-android.conf:143
#    $ndk 来自 ANDROID_NDK_ROOT。若该变量是 Windows 风格 (E:\sdk\android\ndk\...),
#    而 NDK 的 clang 包装器返回 POSIX 路径, 前缀匹配必然失败, 于是落到 else 分支去找
#    $triarch-gcc —— NDK r27 早已删除 gcc, 于是直接 die。
#    实测: 把 ANDROID_NDK_ROOT 与 PATH 统一成 POSIX 风格后该报错消失。
#    注意 cargo-ndk 是原生 Windows 程序 (见 build_rust_lib), 它需要 Windows 风格路径,
#    故两个消费者分别喂各自需要的风格, 不要让一个变量风格统吃。
#
# 2) 并行度 —— macOS 用 sysctl, Windows 没有该命令, 改用 nproc (Git-Bash 自带)。
#
# 3) perl 模块 —— Git for Windows 的 perl 是裁剪版 (x86_64-cygwin), 缺 OpenSSL
#    Configure 必需的 Pod::* / ExtUtils::MakeMaker / CPAN::Meta /
#    Locale::Maketext::Simple 等模块, 缺一个就中止且不产出 Makefile。
#    详见 setup_perl_modules() 与 patch_configure_which()。
# ============================================================

# Windows 盘符路径 → POSIX 路径 (E:\sdk\android → /e/sdk/android)
to_posix_path() {
    local P="$1"
    if command -v cygpath &>/dev/null; then
        cygpath -u "$P" 2>/dev/null || printf '%s' "$P"
    else
        printf '%s' "$P"
    fi
}

# POSIX 路径 → Windows 路径 (供 cargo-ndk 等原生 Windows 程序使用)
to_windows_path() {
    local P="$1"
    if command -v cygpath &>/dev/null; then
        cygpath -w "$P" 2>/dev/null || printf '%s' "$P"
    else
        printf '%s' "$P"
    fi
}

# 并行度: Windows 无 sysctl
cpu_count() {
    if command -v nproc &>/dev/null; then
        nproc
    elif command -v sysctl &>/dev/null; then
        sysctl -n hw.ncpu 2>/dev/null || echo 4
    else
        echo 4
    fi
}

# ============================================================
# 校验 OpenSSL 是否为多线程构建
#
# OpenSSL 4.0 的 Configure 对 `-static` 会隐式执行
# disable('static', 'pic', 'threads'), 使 libcrypto 以单线程 (no-threads) 编译:
# 所有内部锁/原子操作变成空实现, 多线程并发使用 (代理每个连接一个线程) 会
# 破坏 provider 内部状态并触发 SIGSEGV。
#
# 判定方式: threads_pthread.o (受 OPENSSL_THREADS 保护的实现) 是否有符号输出。
# ============================================================
verify_openssl_threads() {
    local LIB="$1"
    local TOOLCHAIN_BIN="$2"
    local OBJ="libcrypto-lib-threads_pthread.o"
    local AR_BIN="$TOOLCHAIN_BIN/llvm-ar"
    local NM_BIN="$TOOLCHAIN_BIN/llvm-nm"
    local TMP_DIR
    TMP_DIR="$(mktemp -d)"

    # 必须显式用 NDK 的 llvm 工具链, 不能回退到系统 ar/nm:
    # macOS 自带 ar 解析不了 ELF 归档 (报 not found in archive), 会得到假阴性并中止构建
    if [ ! -x "$AR_BIN" ] || [ ! -x "$NM_BIN" ]; then
        warn "NDK 工具链缺少 llvm-ar/llvm-nm: $TOOLCHAIN_BIN"
        rm -rf "$TMP_DIR"
        return 2
    fi

    if ! (cd "$TMP_DIR" && "$AR_BIN" x "$LIB" "$OBJ" 2>/dev/null) \
        || ! "$NM_BIN" --defined-only "$TMP_DIR/$OBJ" 2>/dev/null | grep -q "CRYPTO_THREAD_write_lock"; then
        rm -rf "$TMP_DIR"
        return 1
    fi

    rm -rf "$TMP_DIR"
    return 0
}

# ============================================================
# 1. 检查/安装 Rust
# ============================================================
setup_rust() {
    if ! command -v rustc &>/dev/null; then
        log "安装 Rust..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
    fi

    log "Rust: $(rustc --version)"

    # 安装 Android 目标 (多 ABI)
    for spec in "${ABIS[@]}"; do
        local ABI RUST_TARGET _
        read -r ABI RUST_TARGET _ <<<"$spec"
        if ! rustup target list --installed | grep -q "$RUST_TARGET"; then
            log "安装 $RUST_TARGET 目标..."
            rustup target add "$RUST_TARGET"
        fi
    done

    # 安装 cargo-ndk
    if ! command -v cargo-ndk &>/dev/null; then
        log "安装 cargo-ndk..."
        cargo install cargo-ndk
    fi

    log "Rust 工具链就绪"
}

# ============================================================
# 2. 设置 Android NDK 环境
#
# 导出的 ANDROID_NDK_HOME / ANDROID_NDK_ROOT / PATH 一律 POSIX 风格,
# 原因见文件头 (1)。
# ============================================================
setup_ndk() {
    local ANDROID_HOME_POSIX
    ANDROID_HOME_POSIX="$(to_posix_path "${ANDROID_HOME:-$HOME/Library/Android/sdk}")"
    local NDK_DIR="$ANDROID_HOME_POSIX/ndk/$NDK_VERSION"

    if [ ! -d "$NDK_DIR" ]; then
        err "NDK $NDK_VERSION 未找到: $NDK_DIR"
    fi

    # 统一 POSIX 风格: 15-android.conf:107 靠字符串前缀匹配 $ndk 与 which("clang") 的结果
    export ANDROID_HOME="$ANDROID_HOME_POSIX"
    export ANDROID_NDK_HOME="$NDK_DIR"
    export ANDROID_NDK_ROOT="$NDK_DIR"

    # 添加 NDK 工具链到 PATH (用于编译 OpenSSL)
    local TOOLCHAIN_BIN
    TOOLCHAIN_BIN="$(ls -d "$NDK_DIR"/toolchains/llvm/prebuilt/*/bin 2>/dev/null | head -1)"
    if [ -z "$TOOLCHAIN_BIN" ]; then
        err "NDK 工具链未找到: $NDK_DIR/toolchains/llvm/prebuilt/*/bin"
    fi
    export PATH="$TOOLCHAIN_BIN:$PATH"

    log "NDK: $NDK_DIR"
}

# ============================================================
# 2.5 补齐 perl 核心模块 (幂等, 仅 Windows/Git perl 需要)
#
# Git for Windows 的 perl (x86_64-cygwin) 缺少 OpenSSL Configure 需要的
# Pod::* / ExtUtils::MakeMaker / ExtUtils::Manifest / CPAN::Meta /
# Locale::Maketext::Simple 等模块。缺任一模块都表现为:
#   Can't locate Pod/Usage.pm in @INC (...) at configdata.pm line ...
# 然后 Configure 以退出码 2 结束且不产出 Makefile。
#
# 做法: 把运行中 perl 对应版本的核心源码里的 lib/ 补齐到该 perl 自己的 site_perl。
#
# 为什么不用 PERL5LIB (已实测证伪):
#   MSYS 在把环境变量交给 make 子进程时会把 /e/... 转成 E:/..., cygwin perl 再按 ':'
#   分割, 路径被劈成 "E" 和 "/nexhub/..." 两个无效条目, 模块照样找不到。
#   site_perl 是 perl 官方为本地/管理员安装模块预留的目录, 天然在 @INC 中,
#   零环境变量依赖, 不受路径转换影响。
# ============================================================
setup_perl_modules() {
    local PERL_BIN
    PERL_BIN="$(command -v perl 2>/dev/null || true)"
    if [ -z "$PERL_BIN" ]; then
        warn "未找到 perl, 无法编译 OpenSSL (Configure 依赖 perl)"
        return 0
    fi

    # 幂等: 必需模块都在就跳过
    if "$PERL_BIN" -MPod::Usage -MExtUtils::MakeMaker -MExtUtils::Manifest \
        -MCPAN::Meta -MLocale::Maketext::Simple -e1 2>/dev/null; then
        log "perl 模块已就绪, 跳过补齐"
        return 0
    fi

    local PERL_VERSION SITE_LIB
    PERL_VERSION="$("$PERL_BIN" -e 'printf "%vd", $^V')"
    SITE_LIB="$("$PERL_BIN" -MConfig -e 'print $Config::Config{sitelib}')"
    SITE_LIB="$(to_posix_path "$SITE_LIB")"

    if [ -z "$PERL_VERSION" ] || [ -z "$SITE_LIB" ]; then
        warn "无法探测 perl 版本或 site_perl 目录, 跳过补齐"
        return 0
    fi

    log "补齐 perl 模块 ($PERL_VERSION): 系统 perl 缺 OpenSSL Configure 依赖"

    local WORK="$SCRIPT_DIR/.build/perl-core-$PERL_VERSION"
    local TARBALL="$WORK/perl-$PERL_VERSION.tar.gz"
    local SRCDIR="$WORK/perl-$PERL_VERSION"

    mkdir -p "$WORK"

    if [ ! -d "$SRCDIR" ]; then
        local URL=""
        local OK=0
        # 通道顺序: 国内 CPAN 镜像优先, 最后回退官方
        for URL in \
            "https://mirrors.tuna.tsinghua.edu.cn/CPAN/src/5.0/perl-$PERL_VERSION.tar.gz" \
            "https://mirrors.ustc.edu.cn/CPAN/src/5.0/perl-$PERL_VERSION.tar.gz" \
            "https://www.cpan.org/src/5.0/perl-$PERL_VERSION.tar.gz"
        do
            log "  下载 perl 核心源码: $URL"
            if curl -fsSL --retry 3 --retry-delay 3 --max-time 900 -o "$TARBALL" "$URL"; then
                OK=1
                break
            fi
            warn "  该源失败, 换下一个"
            rm -f "$TARBALL"
        done

        if [ "$OK" -ne 1 ]; then
            err "perl 源码下载失败, 无法补齐模块 (试试 tuna/ustc/cpan.org 任一可达的网络)"
        fi

        # 完整性校验: 截断的 tar.gz 会在解压后才以莫名其妙的错误爆出来
        tar tzf "$TARBALL" >/dev/null 2>&1 || err "perl 源码压缩包损坏: $TARBALL"
        tar xzf "$TARBALL" -C "$WORK"
        rm -f "$TARBALL"
    fi

    [ -d "$SRCDIR" ] || err "perl 源码目录不存在: $SRCDIR"

    # 核心 lib/ + cpan/*/lib + dist/*/lib + ext/*/lib 合并到一个 staging 目录
    local STAGE="$WORK/stage"
    local D
    rm -rf "$STAGE"
    mkdir -p "$STAGE/lib"
    for D in "$SRCDIR/lib" "$SRCDIR"/cpan/*/lib "$SRCDIR"/dist/*/lib "$SRCDIR"/ext/*/lib; do
        [ -d "$D" ] || continue
        cp -R "$D"/. "$STAGE/lib"/
    done

    # -n 不覆盖已存在文件: 只补缺口, 不破坏现有环境
    mkdir -p "$SITE_LIB"
    cp -Rn "$STAGE"/lib/. "$SITE_LIB"/
    log "  已补入 $SITE_LIB (现有 $(find "$SITE_LIB" -type f | wc -l) 个文件)"

    # 复核: 仍缺必需模块就失败, 不要带着半残环境去 Configure (否则错误现场离根因很远)
    if ! "$PERL_BIN" -MPod::Usage -MExtUtils::MakeMaker -e1 2>/dev/null; then
        err "perl 模块补齐后仍缺 Pod::Usage / ExtUtils::MakeMaker, 请检查 $SITE_LIB"
    fi
    log "perl 模块补齐完成"
}

# ============================================================
# 2.6 给 OpenSSL Configure 的 which() 加深度探测 (幂等)
#
# OpenSSL Configure 的 sub which (Configure:3433) 走 IPC::Cmd::can_run, 而
# IPC::Cmd::can_run 内部才 require ExtUtils::MakeMaker (IPC/Cmd.pm:236, 运行时依赖,
# 顶层 require IPC::Cmd 探测不出来)。模块缺失时 can_run 直接 die, 而原写法
#   if (eval { require IPC::Cmd; 1; })
# 只探测了 IPC::Cmd 本身, 于是 die 逃出 eval 变成致命错误。
#
# 补丁把探测加深到真正调用一次 can_run, 让模块缺失时能落到 OpenSSL 作者手写的
# PATH 遍历 fallback 分支 —— 缺模块不再是硬失败, 只是能力降级。
# (模块已由 setup_perl_modules 补上, 这里是防御性的双保险)
# ============================================================
patch_configure_which() {
    local CFG="$1"
    [ -f "$CFG" ] || return 0

    if grep -q 'IPC::Cmd::can_run("sh")' "$CFG"; then
        log "Configure which() 补丁已存在, 跳过"
        return 0
    fi

    cp "$CFG" "$CFG.orig"
    perl -0777 -pi -e 's/if \(eval \{ require IPC::Cmd; 1; \}\)/if (eval { require IPC::Cmd; IPC::Cmd::can_run("sh"); 1; })/' "$CFG"

    if grep -q 'IPC::Cmd::can_run("sh")' "$CFG"; then
        log "已应用 Configure which() 深度探测补丁 (备份: Configure.orig)"
    else
        warn "Configure which() 补丁未生效 (上游结构可能已变), 继续构建"
    fi
}

# ============================================================
# 3. 交叉编译 OpenSSL (带 ECH 支持) —— 按 ABI 独立构建
#
# 用法: build_openssl <jniLibs-abi> <openssl-configure-target>
#   例: build_openssl arm64-v8a android-arm64
#
# 源码默认自动下载; 也可手动放到:
#   android/rust/openssl/build/openssl-4.0.1/
#
# 产物目录按 ABI 分离 (openssl/install-<abi>): Configure target 与指令集
# 随 ABI 变化, 共用一个目录会让第二个 ABI 复用第一个的配置产物。
# ============================================================
build_openssl() {
    local ABI="$1"
    local SSL_TARGET="$2"
    local OPENSSL_DIR="$SCRIPT_DIR/openssl"
    local OPENSSL_BUILD="$OPENSSL_DIR/build"
    local OPENSSL_INSTALL="$OPENSSL_DIR/install-$ABI"
    local OPENSSL_SRC="$OPENSSL_BUILD/openssl-$OPENSSL_VERSION"
    local ANDROID_HOME_POSIX
    ANDROID_HOME_POSIX="$(to_posix_path "${ANDROID_HOME:-$HOME/Library/Android/sdk}")"
    local NDK_DIR="$ANDROID_HOME_POSIX/ndk/$NDK_VERSION"
    local TOOLCHAIN
    local API_LEVEL=21

    # 兼容迁移: 旧版单 ABI 产物目录 install/ 即 arm64-v8a, 有校验标记就整体改名复用
    if [ "$ABI" = "arm64-v8a" ] && [ ! -d "$OPENSSL_INSTALL" ] \
        && [ -f "$OPENSSL_DIR/install/lib/libssl.a" ] && [ -f "$OPENSSL_DIR/install/.threads-ok" ]; then
        log "迁移旧版 arm64-v8a OpenSSL 产物: install/ → install-arm64-v8a/"
        mv "$OPENSSL_DIR/install" "$OPENSSL_INSTALL"
    fi

    # host 目录名随 NDK 版本/主机架构变化 (darwin-x86_64 / darwin-arm64 / windows-x86_64 ...),
    # 按实际存在值取
    TOOLCHAIN="$(ls -d "$NDK_DIR"/toolchains/llvm/prebuilt/* 2>/dev/null | head -1)"
    if [ -z "$TOOLCHAIN" ]; then
        err "NDK 工具链未找到: $NDK_DIR/toolchains/llvm/prebuilt/*"
    fi

    # 只有带 threads 校验标记的产物才可复用
    if [ -f "$OPENSSL_INSTALL/lib/libssl.a" ] && [ -f "$OPENSSL_INSTALL/.threads-ok" ]; then
        log "OpenSSL [$ABI] 已编译 (threads 已启用), 跳过"
        export OPENSSL_DIR="$OPENSSL_INSTALL"
        export OPENSSL_INCLUDE_DIR="$OPENSSL_INSTALL/include"
        export OPENSSL_LIB_DIR="$OPENSSL_INSTALL/lib"
        export OPENSSL_STATIC=1
        return
    fi

    if [ -f "$OPENSSL_INSTALL/lib/libssl.a" ]; then
        warn "检测到 [$ABI] 旧的 OpenSSL 产物 (可能是 no-threads 构建), 删除后重新编译"
        rm -rf "$OPENSSL_INSTALL"
    fi

    # 检查源码是否存在, 不存在则自动下载
    #
    # 通道顺序: 先走 GitHub release 加速镜像, 最后官方地址。
    # 直接从 github.com 拉 release 资产在部分网络下会中途断流
    # (实测 curl: (18) transfer closed with outstanding read data remaining),
    # 且 codeload 不支持 Range 续传 —— 断一次就得整包重下, 故给多源。
    if [ ! -d "$OPENSSL_SRC" ]; then
        warn "OpenSSL 源码未找到: $OPENSSL_SRC"
        mkdir -p "$OPENSSL_BUILD"

        local REL="openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"
        local TARBALL="$OPENSSL_BUILD/openssl-$OPENSSL_VERSION.tar.gz"
        local URL=""
        local OK=0
        for URL in \
            "https://gh-proxy.com/https://github.com/openssl/openssl/releases/download/$REL" \
            "https://ghfast.top/https://github.com/openssl/openssl/releases/download/$REL" \
            "https://github.com/openssl/openssl/releases/download/$REL"
        do
            log "下载 OpenSSL $OPENSSL_VERSION: $URL"
            if curl -fL --retry 3 --retry-delay 3 --max-time 1800 -o "$TARBALL" "$URL"; then
                OK=1
                break
            fi
            warn "  该源失败, 换下一个"
            rm -f "$TARBALL"
        done

        if [ "$OK" -ne 1 ]; then
            err "OpenSSL 源码下载失败, 请手动下载并解压到: $OPENSSL_SRC"
        fi

        # 完整性校验: 截断的压缩包会在后面以莫名其妙的编译错误爆出来
        tar tzf "$TARBALL" >/dev/null 2>&1 || err "OpenSSL 压缩包损坏 (可能被截断): $TARBALL"
        tar xzf "$TARBALL" -C "$OPENSSL_BUILD"
        rm -f "$TARBALL"

        if [ ! -d "$OPENSSL_SRC" ]; then
            err "解压后目录不符, 期望: $OPENSSL_SRC"
        fi

        # ECH 支持是编译目标本身, 缺头文件会静默退化成 no_ech 变体, 必须显式挡掉
        if [ ! -f "$OPENSSL_SRC/include/openssl/ech.h" ]; then
            err "OpenSSL 源码缺少 include/openssl/ech.h, 无法编译 ECH 支持"
        fi
    fi

    log "编译 OpenSSL $OPENSSL_VERSION (带 ECH 支持)..."
    mkdir -p "$OPENSSL_INSTALL"

    cd "$OPENSSL_SRC"

    # Windows/Git perl 预处理: 补模块 + 给 which() 加深探测
    setup_perl_modules
    patch_configure_which "$OPENSSL_SRC/Configure"
    rm -f "$OPENSSL_SRC/Makefile" "$OPENSSL_SRC/configdata.pm"

    # 配置交叉编译
    #
    # 注意: 这里不能传 -static。OpenSSL 4.0 的 Configure 视 -static 为 LDFLAGS,
    # 会隐式 disable('static', 'pic', 'threads') (且位于用户参数解析之后, 显式写
    # threads 也会被覆盖), 结果是 libcrypto 以单线程 (no-threads) 编译、所有内部锁
    # 变成空操作, 多线程代理并发使用 OpenSSL 时必崩 (SSL_CTX_new_ex → SIGSEGV)。
    # 静态库能力由 no-shared 保证 (配合 OPENSSL_STATIC=1 静态链接进 libechproxy.so)。
    ./Configure "$SSL_TARGET" -D__ANDROID_API__=$API_LEVEL \
        --prefix="$OPENSSL_INSTALL" \
        --openssldir="$OPENSSL_INSTALL" \
        no-shared \
        no-tests

    # 清掉可能残留的旧编译产物, 避免沿用旧配置编译出的目标文件
    make clean >/dev/null 2>&1 || true

    make -j"$(cpu_count)"
    make install_sw

    # 产物自检: 单线程构建的 OpenSSL 会让 ECH 代理随机闪崩, 直接失败退出
    local VERIFY_RC=0
    verify_openssl_threads "$OPENSSL_INSTALL/lib/libcrypto.a" "$TOOLCHAIN/bin" || VERIFY_RC=$?
    if [ "$VERIFY_RC" -eq 2 ]; then
        err "NDK 工具链缺少 llvm-ar/llvm-nm, 无法校验 OpenSSL 产物: $TOOLCHAIN/bin"
    elif [ "$VERIFY_RC" -ne 0 ]; then
        err "OpenSSL [$ABI] 编译产物缺少多线程支持 (no-threads), 会导致代理并发崩溃, 请检查 Configure 参数"
    fi

    touch "$OPENSSL_INSTALL/.threads-ok"
    log "OpenSSL [$ABI] 多线程支持校验通过"

    export OPENSSL_DIR="$OPENSSL_INSTALL"
    export OPENSSL_INCLUDE_DIR="$OPENSSL_INSTALL/include"
    export OPENSSL_LIB_DIR="$OPENSSL_INSTALL/lib"
    export OPENSSL_STATIC=1

    log "OpenSSL [$ABI] 编译完成"
}

# ============================================================
# 4. 交叉编译 Rust 库 —— 按 ABI 构建
#
# 用法: build_rust_lib <jniLibs-abi> <rust-target>
# ============================================================
build_rust_lib() {
    local ABI="$1"
    local RUST_TARGET="$2"
    cd "$SCRIPT_DIR"

    log "编译 ech-proxy ($RUST_TARGET)..."

    # cargo-ndk 是原生 Windows 程序, 需要 Windows 风格路径;
    # 而 OpenSSL Configure 需要 POSIX 风格 (见文件头 1) —— 分别喂, 互不干扰。
    local SDK_POSIX
    SDK_POSIX="$(to_posix_path "${ANDROID_HOME:-$HOME/Library/Android/sdk}")"
    local NDK_POSIX="${ANDROID_NDK_ROOT:-$SDK_POSIX/ndk/$NDK_VERSION}"
    local NDK_WIN SDK_WIN
    NDK_WIN="$(to_windows_path "$NDK_POSIX")"
    SDK_WIN="$(to_windows_path "$SDK_POSIX")"

    ANDROID_HOME="$SDK_WIN" \
    ANDROID_NDK_HOME="$NDK_WIN" \
    ANDROID_NDK_ROOT="$NDK_WIN" \
    cargo ndk -t "$ABI" --platform 21 build --release 2>&1

    # 复制产物到 jniLibs
    local SO_FILE="$SCRIPT_DIR/target/$RUST_TARGET/release/libechproxy.so"
    local JNILIBS_DIR="$JNILIBS_ROOT/$ABI"

    if [ -f "$SO_FILE" ]; then
        mkdir -p "$JNILIBS_DIR"
        cp "$SO_FILE" "$JNILIBS_DIR/"
        log "已复制到 $JNILIBS_DIR/libechproxy.so"
        log "大小: $(du -h "$JNILIBS_DIR/libechproxy.so" | cut -f1)"

        # JNI 符号自检: 符号名与 Kotlin 包名/类名必须严格对应,
        # 对不上时 App 只在运行时报 UnsatisfiedLinkError, 构建期不报错 —— 太晚。
        local NM_BIN="$NDK_POSIX/toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-nm"
        [ -x "$NM_BIN" ] || NM_BIN="$(ls -d "$NDK_POSIX"/toolchains/llvm/prebuilt/*/bin/llvm-nm 2>/dev/null | head -1)"
        if [ -x "$NM_BIN" ]; then
            local EXPECTED="Java_com_nexhub_app_EchProxyNative_"
            local FOUND
            FOUND="$("$NM_BIN" --defined-only "$SO_FILE" 2>/dev/null | grep -c "$EXPECTED" || true)"
            if [ "$FOUND" -ge 4 ]; then
                log "JNI 符号自检通过 ($FOUND 个 $EXPECTED* 符号)"
            else
                err "JNI 符号自检失败: 只找到 $FOUND 个 ${EXPECTED}* 符号 (期望 4)"
            fi
        fi
    else
        err "编译产物未找到: $SO_FILE"
    fi
}

# ============================================================
# Main
# ============================================================
main() {
    log "=== ECH Proxy 编译 (Android 多 ABI) ==="

    if [ "${1:-}" = "--setup" ]; then
        setup_rust
        setup_ndk
        setup_perl_modules
        log "工具链准备完成"
        exit 0
    fi

    setup_rust
    setup_ndk

    # 只建单个 ABI: ./build-android.sh arm64-v8a；否则三个 ABI 全量构建
    local ONLY_ABI="${1:-}"
    local SPEC
    for SPEC in "${ABIS[@]}"; do
        local ABI RUST_TARGET SSL_TARGET
        read -r ABI RUST_TARGET SSL_TARGET <<<"$SPEC"
        if [ -n "$ONLY_ABI" ] && [ "$ONLY_ABI" != "$ABI" ]; then
            continue
        fi
        log "── ABI: $ABI ──"
        build_openssl "$ABI" "$SSL_TARGET"
        build_rust_lib "$ABI" "$RUST_TARGET"
    done

    log "=== 编译完成 ==="
    log ""
    log "产物: $JNILIBS_ROOT/<abi>/libechproxy.so"
    log ""
    log "下一步:"
    log "  1. 重新编译 Android App (gradle 会把 jniLibs 打进 APK)"
    log "  2. Dart 侧 BangumiEchProxy.enableEchProxy() 会自动经 nexhub/ech_proxy 通道调用"
    log "  3. 桌面端 (Windows/Linux/macOS) 另见 build-windows.sh / build-desktop.sh"
}

main "$@"
