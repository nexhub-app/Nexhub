#!/bin/bash
set -e

# ============================================================
# ECH Proxy - Windows 桌面构建 (echproxy.dll)
#
# 产物经 dart:ffi 加载 (DynamicLibrary.open('echproxy.dll'))，
# 与 Android 共用同一份 Rust 源码与 C API (lib.rs 的 ech_*)。
#
# 环境要求 (本机即可，无需 NDK):
#   - Rust: x86_64-pc-windows-msvc target
#   - Visual Studio (Community/BuildTools) 含 VC 工具链 (cl/nmake/link)
#     脚本用 vswhere 自动定位，找不到时可用环境变量 VSWHERE_PATH 指定
#   - perl: Git for Windows 自带 (缺模块时自动补齐，同 build-android.sh)
#
# 用法 (Git-Bash):
#   bash build-android/rust/build-windows.sh          # OpenSSL(win64) + echproxy.dll
#   bash build-windows.sh --setup                     # 仅准备工具链 (rust target / perl 模块)
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DLL_OUT_DIR="$PROJECT_ROOT/windows/dll"
OPENSSL_VERSION="4.0.1"
RUST_TARGET="x86_64-pc-windows-msvc"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

# printf 而非 echo -e：echo -e 会把 Windows 路径里的 \v (\vcvars64) 吃成垂直制表符
log() { printf '%s[build]%s %s\n' "$GREEN" "$NC" "$1"; }
warn() { printf '%s[warn]%s %s\n' "$YELLOW" "$NC" "$1"; }
err() { printf '%s[error]%s %s\n' "$RED" "$NC" "$1"; exit 1; }

to_posix_path() {
    local P="$1"
    if command -v cygpath &>/dev/null; then
        cygpath -u "$P" 2>/dev/null || printf '%s' "$P"
    else
        printf '%s' "$P"
    fi
}

to_windows_path() {
    local P="$1"
    if command -v cygpath &>/dev/null; then
        cygpath -w "$P" 2>/dev/null || printf '%s' "$P"
    else
        printf '%s' "$P"
    fi
}

# ============================================================
# 定位 VS 的 vcvars64.bat (cl/nmake/link 环境初始化)
# ============================================================
setup_vs_env() {
    local VSWHERE_DEFAULT="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
    local VSWHERE="${VSWHERE_PATH:-$VSWHERE_DEFAULT}"
    [ -x "$VSWHERE" ] || err "vswhere 未找到: $VSWHERE (确认已安装 Visual Studio / Build Tools)"

    local VS_PATH
    VS_PATH="$("$VSWHERE" -latest -products '*' \
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 \
        -property installationPath | tail -1 | tr -d '\r')"
    [ -n "$VS_PATH" ] || err "未找到含 VC 工具链的 Visual Studio (vswhere 查询为空)"

    VCVARS_BAT="$(to_windows_path "$(to_posix_path "$VS_PATH")/VC/Auxiliary/Build/vcvars64.bat")"
    [ -f "$VCVARS_BAT" ] || err "vcvars64.bat 未找到: $VCVARS_BAT"
    log "VS 环境: $VCVARS_BAT"
}

# 在 VS 环境里执行一段命令 (临时 .cmd 批处理，规避 cmd //c 的嵌套引号问题)
run_in_vs_env() {
    local WORKDIR="$1"; shift
    local BATCH="$SCRIPT_DIR/.build/vsenv-$$.cmd"
    mkdir -p "$SCRIPT_DIR/.build"
    {
        echo '@echo off'
        echo "call \"$VCVARS_BAT\" >nul"
        # NASM 就位后注入 PATH (OpenSSL 的 .asm 需要)
        if [ -n "${NASM_DIR_WIN:-}" ]; then
            echo "set \"PATH=$NASM_DIR_WIN;%PATH%\""
        fi
        echo "cd /d \"$(to_windows_path "$WORKDIR")\""
        echo "$*"
        echo 'exit /b %ERRORLEVEL%'
    } > "$BATCH"
    local OUT RC=0
    OUT="$(cmd //c "$(to_windows_path "$BATCH")" 2>&1)" || RC=$?
    [ -n "$OUT" ] && printf '%s\n' "$OUT" | tail -40
    rm -f "$BATCH"
    return $RC
}

# ============================================================
# 0.5 原生 perl (OpenSSL VC-WIN64A 硬性要求)
#
# OpenSSL 的 Configure 对 VC 目标会显式拒绝 cygwin/msys perl
# ("doesn't produce Windows like paths")，Git-Bash 自带的 perl 正是 cygwin 版。
# 机器上没有原生 perl (Strawberry/ActiveState) 时，从 StrawberryPerl 的
# GitHub release (经 gh-proxy 加速) 下载 portable 版缓存到 .build/。
# ============================================================
ensure_native_perl() {
    local SYS_PERL
    SYS_PERL="$(command -v perl 2>/dev/null || true)"
    if [ -n "$SYS_PERL" ] && "$SYS_PERL" -e 'exit($^O eq "MSWin32" ? 0 : 1)' 2>/dev/null; then
        PERL_WIN="$SYS_PERL"
        log "原生 perl (PATH): $PERL_WIN"
        return 0
    fi

    local SP_VER="5.42.3.1"
    local WORK="$SCRIPT_DIR/.build/strawberry-perl"
    local PERL_EXE="$WORK/perl/bin/perl.exe"
    if [ -x "$PERL_EXE" ]; then
        PERL_WIN="$(to_windows_path "$PERL_EXE")"
        log "原生 perl (Strawberry portable 缓存): $PERL_WIN"
        return 0
    fi

    local ZIP="$SCRIPT_DIR/.build/strawberry-perl-$SP_VER-portable.zip"
    local GH_URL="https://github.com/StrawberryPerl/Perl-Dist-Strawberry/releases/download/SP_54231_64bit/strawberry-perl-$SP_VER-64bit-portable.zip"
    local URL="" OK=0
    for URL in "https://gh-proxy.com/$GH_URL" "$GH_URL"; do
        log "下载原生 perl (Strawberry $SP_VER portable, ~320MB, 一次性缓存): $URL"
        if curl -fL --retry 3 --retry-delay 3 --max-time 1800 -o "$ZIP" "$URL"; then
            OK=1; break
        fi
        rm -f "$ZIP"
    done
    [ "$OK" -eq 1 ] || err "原生 perl 下载失败 (OpenSSL VC 构建必需); 也可手动安装 Strawberry Perl 后重跑"

    mkdir -p "$WORK"
    unzip -o -q "$ZIP" -d "$WORK"
    rm -f "$ZIP"
    [ -x "$PERL_EXE" ] || err "perl.exe 解压后未找到: $PERL_EXE"
    PERL_WIN="$(to_windows_path "$PERL_EXE")"
    log "原生 perl 就位: $PERL_WIN"
}

# ============================================================
# 0. NASM (OpenSSL VC-WIN64A 汇编器依赖)
#
# VS 不自带 NASM；本机无包管理器时从 nasm.us 下载官方 win64 版到 .build/。
# 下载失败则回退 no-asm 构建（纯 C 实现，功能不变，crypto 吞吐下降）。
# ============================================================
ensure_nasm() {
    if command -v nasm >/dev/null 2>&1; then
        log "NASM: $(command -v nasm)"
        return 0
    fi
    local NASM_VER="2.16.03"
    local WORK="$SCRIPT_DIR/.build/nasm-$NASM_VER"
    if [ -x "$WORK/nasm.exe" ]; then
        NASM_DIR_WIN="$(to_windows_path "$WORK")"
        log "NASM (已缓存): $NASM_DIR_WIN"
        return 0
    fi

    local ZIP="$SCRIPT_DIR/.build/nasm-$NASM_VER-win64.zip"
    local URL="" OK=0
    for URL in \
        "https://www.nasm.us/pub/nasm/releasebuilds/$NASM_VER/win64/nasm-$NASM_VER-win64.zip" \
        "https://gh-proxy.com/https://www.nasm.us/pub/nasm/releasebuilds/$NASM_VER/win64/nasm-$NASM_VER-win64.zip"
    do
        log "下载 NASM: $URL"
        if curl -fL --retry 2 --retry-delay 3 --max-time 600 -o "$ZIP" "$URL"; then
            OK=1; break
        fi
        rm -f "$ZIP"
    done
    if [ "$OK" -ne 1 ]; then
        warn "NASM 下载失败, 回退 no-asm 构建 (crypto 吞吐下降, 功能不受影响)"
        ECH_NO_ASM=1
        return 0
    fi

    mkdir -p "$WORK"
    unzip -o -q "$ZIP" -d "$SCRIPT_DIR/.build/nasm-tmp"
    find "$SCRIPT_DIR/.build/nasm-tmp" -name 'nasm.exe' -exec cp {} "$WORK/" \;
    find "$SCRIPT_DIR/.build/nasm-tmp" -name 'ndisasm.exe' -exec cp {} "$WORK/" \;
    rm -rf "$SCRIPT_DIR/.build/nasm-tmp" "$ZIP"

    if [ -x "$WORK/nasm.exe" ]; then
        NASM_DIR_WIN="$(to_windows_path "$WORK")"
        log "NASM 就位: $NASM_DIR_WIN"
    else
        warn "NASM 解压失败, 回退 no-asm 构建"
        ECH_NO_ASM=1
    fi
}

patch_configure_which() {
    local CFG="$1"
    [ -f "$CFG" ] || return 0
    if grep -q 'IPC::Cmd::can_run("sh")' "$CFG"; then
        return 0
    fi
    cp "$CFG" "$CFG.orig"
    perl -0777 -pi -e 's/if \(eval \{ require IPC::Cmd; 1; \}\)/if (eval { require IPC::Cmd; IPC::Cmd::can_run("sh"); 1; })/' "$CFG"
    grep -q 'IPC::Cmd::can_run("sh")' "$CFG" \
        && log "已应用 Configure which() 深度探测补丁" \
        || warn "Configure which() 补丁未生效 (上游结构可能已变), 继续构建"
}

# ============================================================
# 1. Rust 工具链
# ============================================================
setup_rust() {
    if ! command -v rustc &>/dev/null; then
        err "未找到 rustc (https://rustup.rs 安装后重试)"
    fi
    if ! rustup target list --installed | grep -q "$RUST_TARGET"; then
        log "安装 $RUST_TARGET 目标..."
        rustup target add "$RUST_TARGET"
    fi
    log "Rust: $(rustc --version) ($RUST_TARGET)"
}

# ============================================================
# 2. 编译 OpenSSL 4.0.1 (VC-WIN64A, 带 ECH 支持, 静态)
#
# 源码与 Android 共用 openssl/build/openssl-<ver>/；产物独立到 install-win64/
# ============================================================
build_openssl_windows() {
    local OPENSSL_DIR="$SCRIPT_DIR/openssl"
    local OPENSSL_BUILD="$OPENSSL_DIR/build"
    local OPENSSL_INSTALL="$OPENSSL_DIR/install-win64"
    local OPENSSL_SRC="$OPENSSL_BUILD/openssl-$OPENSSL_VERSION"

    if [ -f "$OPENSSL_INSTALL/lib/libssl.lib" ] && [ -f "$OPENSSL_INSTALL/lib/libcrypto.lib" ] \
        && [ -f "$OPENSSL_INSTALL/.threads-ok" ]; then
        log "OpenSSL (win64) 已编译, 跳过"
        export OPENSSL_DIR="$OPENSSL_INSTALL"
        export OPENSSL_INCLUDE_DIR="$OPENSSL_INSTALL/include"
        export OPENSSL_LIB_DIR="$OPENSSL_INSTALL/lib"
        export OPENSSL_STATIC=1
        return
    fi

    [ -d "$OPENSSL_SRC" ] || err "OpenSSL 源码未找到: $OPENSSL_SRC (先跑一次 build-android.sh 会自动下载)"
    [ -f "$OPENSSL_SRC/include/openssl/ech.h" ] || err "OpenSSL 源码缺少 ech.h, 无法编译 ECH 支持"

    log "编译 OpenSSL $OPENSSL_VERSION (VC-WIN64A, 带 ECH 支持)..."

    # Configure 阶段就要探测 nasm (与 nmake 阶段一样需要), 注入 bash 侧 PATH
    if [ -n "${NASM_DIR_WIN:-}" ]; then
        export PATH="$(to_posix_path "$NASM_DIR_WIN"):$PATH"
    fi

    # 清掉上一个 ABI (Android) 的产物, 避免混入 ELF 目标文件
    (cd "$OPENSSL_SRC" && make clean >/dev/null 2>&1) \
        || find "$OPENSSL_SRC" -name '*.o' -delete 2>/dev/null || true

    # 原生 perl (Strawberry/PATH) 自带完整核心模块, 无需 build-android.sh 的补齐流程
    patch_configure_which "$OPENSSL_SRC/Configure"
    rm -f "$OPENSSL_SRC/Makefile" "$OPENSSL_SRC/configdata.pm"

    mkdir -p "$OPENSSL_INSTALL"

    # Configure 用原生 perl 跑 (cygwin perl 会被 OpenSSL 拒绝); prefix 用 Windows 路径
    local ASM_FLAGS=""
    if [ "${ECH_NO_ASM:-0}" = "1" ]; then
        ASM_FLAGS="no-asm"
        warn "以 no-asm 配置 OpenSSL (无 NASM)"
    fi
    (cd "$OPENSSL_SRC" && "$PERL_WIN" Configure VC-WIN64A $ASM_FLAGS \
        "--prefix=$(to_windows_path "$OPENSSL_INSTALL")" \
        "--openssldir=$(to_windows_path "$OPENSSL_INSTALL")" \
        no-shared no-tests)

    # nmake 需要 cl/link 环境 → 在 vcvars 环境里执行
    run_in_vs_env "$OPENSSL_SRC" 'nmake /nologo' \
        || err "OpenSSL nmake 失败 (vcvars64 环境问题?)"
    run_in_vs_env "$OPENSSL_SRC" 'nmake /nologo install_sw' \
        || err "OpenSSL install_sw 失败"

    [ -f "$OPENSSL_INSTALL/lib/libssl.lib" ] || err "未找到 $OPENSSL_INSTALL/lib/libssl.lib"
    [ -f "$OPENSSL_INSTALL/lib/libcrypto.lib" ] || err "未找到 $OPENSSL_INSTALL/lib/libcrypto.lib"

    # 多线程构建自检 (对齐 Android 脚本): no-threads 的 libcrypto 会让代理并发崩溃。
    # dumpbin 在 vcvars 环境里对静态库直接枚举符号。
    run_in_vs_env "$OPENSSL_INSTALL/lib" 'dumpbin /SYMBOLS libcrypto.lib | findstr /C:CRYPTO_THREAD_write_lock >nul && echo THREADS_OK' \
        | grep -q THREADS_OK || err "OpenSSL 编译产物缺少多线程支持 (no-threads), 请检查 Configure 参数"
    touch "$OPENSSL_INSTALL/.threads-ok"

    export OPENSSL_DIR="$OPENSSL_INSTALL"
    export OPENSSL_INCLUDE_DIR="$OPENSSL_INSTALL/include"
    export OPENSSL_LIB_DIR="$OPENSSL_INSTALL/lib"
    export OPENSSL_STATIC=1
    log "OpenSSL (win64) 编译完成"
}

# ============================================================
# 3. 编译 Rust cdylib → echproxy.dll
#
# +crt-static: CRT 静态链接进 DLL, 产物不依赖用户机器上的 VC++ 运行库
# ============================================================
build_rust_dll() {
    cd "$SCRIPT_DIR"
    log "编译 ech-proxy ($RUST_TARGET, cdylib)..."

    run_in_vs_env "$SCRIPT_DIR" \
        "set OPENSSL_DIR=$(to_windows_path "$OPENSSL_DIR")&& set OPENSSL_STATIC=1&& set RUSTFLAGS=-C target-feature=+crt-static&& cargo build --release --target $RUST_TARGET" \
        || err "cargo build 失败"

    local DLL_SRC="$SCRIPT_DIR/target/$RUST_TARGET/release/echproxy.dll"
    [ -f "$DLL_SRC" ] || err "编译产物未找到: $DLL_SRC"

    mkdir -p "$DLL_OUT_DIR"
    cp "$DLL_SRC" "$DLL_OUT_DIR/"
    log "已复制到 $DLL_OUT_DIR/echproxy.dll ($(du -h "$DLL_OUT_DIR/echproxy.dll" | cut -f1))"

    # C 导出符号自检: Dart FFI 侧按这些名字绑定
    run_in_vs_env "$DLL_OUT_DIR" 'dumpbin /EXPORTS echproxy.dll | findstr /C:ech_ && echo SYMBOLS_OK' \
        | grep -q SYMBOLS_OK || err "DLL 缺少 ech_* 导出符号 (lib.rs 的 C API 模块未编译进去?)"
}

# ============================================================
# Main
# ============================================================
main() {
    log "=== ECH Proxy 编译 (Windows 桌面) ==="

    if [ "${1:-}" = "--setup" ]; then
        setup_rust
        setup_vs_env
        ensure_native_perl
        ensure_nasm
        log "工具链准备完成"
        exit 0
    fi

    setup_rust
    setup_vs_env
    ensure_native_perl
    ensure_nasm
    build_openssl_windows
    build_rust_dll

    log "=== 编译完成 ==="
    log ""
    log "产物: $DLL_OUT_DIR/echproxy.dll"
    log ""
    log "下一步:"
    log "  1. flutter run/build -d windows 会经 windows/CMakeLists.txt 把 DLL 复制到 exe 目录"
    log "  2. Dart 侧 BangumiEchProxy 经 dart:ffi 调用 ech_start_proxy / ech_set_scope 等 C API"
}

main "$@"
