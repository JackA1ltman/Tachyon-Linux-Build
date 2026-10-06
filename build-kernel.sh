#!/usr/bin/env bash
# linux-tachyon 编译脚本 —— 第 1+2 部分
#   1. 克隆 AUR 仓库、makepkg 编译、记录产物文件名写入 $GITHUB_ENV
#   2. --skip-if-released：编译前比对 AUR 最新版本与 GitHub 最新 release，
#      一致则跳过本次编译
#
# 运行环境：GitHub Actions 的 archlinux:base 容器（以 root 运行），
# 也可在本机非 root 用户下直接运行调试（需已安装 base-devel 及 makedepends）。
set -euo pipefail

### ── 可配置项（均可用环境变量覆盖）──────────────────────────────
AUR_REPO_URL="${AUR_REPO_URL:-https://aur.archlinux.org/linux-tachyon.git}"
BUILD_ROOT="${BUILD_ROOT:-$PWD/tachyon-build}"
AUR_PKG_NAME="linux-tachyon"
# _subarch 留空时 make oldconfig 会停在交互选择，CI 中必须指定：
#   1 = GENERIC_CPU（通用 x86-64，最安全），配合 SUBARCH_MICROARCH=1/2/3/4；
#   也可填编号 2~42 或 Kconfig 名，如 MZEN4、MRAPTORLAKE。
SUBARCH="${SUBARCH:-1}"
SUBARCH_MICROARCH="${SUBARCH_MICROARCH:-1}"
# y=强制开 / n=强制关 DEBUG_INFO。默认 n：编译更快、包更小（BTF/DWARF 全关）。
DEBUG="${DEBUG:-n}"
# 置 1 启用 LLVM/LTO（PKGBUILD 作者标注为实验性）
USE_LLVM_LTO="${USE_LLVM_LTO:-}"
# CI 容器内没有 kernel.org 维护者的 PGP 公钥，默认跳过签名校验。
# sha256sums 校验始终执行，不受此开关影响。置 0 需自行导入密钥。
SKIP_PGP_CHECK="${SKIP_PGP_CHECK:-1}"
# GitHub API 地址（测试或 GHES 环境可覆盖）
GITHUB_API_BASE="${GITHUB_API_BASE:-https://api.github.com}"

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: build-kernel.sh [选项]

选项:
  --skip-if-released   编译前比对 AUR 最新版本与 GitHub 最新 release 的 tag，
                       一致则跳过编译（通过 TACHYON_SKIP=1 通知后续步骤）
  --repo owner/name    指定 GitHub 仓库（默认取 $GITHUB_REPOSITORY，
                       Actions 中无需手动传）
  --force              版本一致时也强制重新编译
  -h, --help           显示本帮助

编译配置通过环境变量覆盖:
  AUR_REPO_URL / BUILD_ROOT / SUBARCH / SUBARCH_MICROARCH / DEBUG /
  USE_LLVM_LTO / SKIP_PGP_CHECK
EOF
}

### ── 0. 参数解析 ────────────────────────────────────────────────
SKIP_IF_RELEASED=0
FORCE=0
GH_REPO="${GITHUB_REPOSITORY:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-if-released) SKIP_IF_RELEASED=1 ;;
    --repo) [ $# -ge 2 ] || die "--repo 需要参数 owner/name"; GH_REPO=$2; shift ;;
    --repo=*) GH_REPO="${1#*=}" ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1（--help 查看用法）" ;;
  esac
  shift
done

MAKEPKG_FLAGS=(--noconfirm)
if [ "$SKIP_PGP_CHECK" = "1" ]; then
  MAKEPKG_FLAGS+=(--skippgpcheck)
fi

### ── 1. 版本检查：AUR 最新版 == GitHub 最新 release 则跳过编译 ──
# 返回 AUR RPC API 中的 Version 字段，即 AUR 页面 "Package Details" 显示的
# pkgver-pkgrel
fetch_aur_version() {
  local resp v
  if ! resp=$(curl -sS -G 'https://aur.archlinux.org/rpc/' \
      --data-urlencode 'v=5' --data-urlencode 'type=info' \
      --data-urlencode "arg[]=$AUR_PKG_NAME"); then
    return 1
  fi
  v=$(printf '%s' "$resp" | grep -oP '"Version"\s*:\s*"\K[^"]+' | head -n1)
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# 输出最新 release 的 tag 名；返回码 2 = 仓库尚无 release（HTTP 404）
fetch_latest_release_tag() {
  local url tmp code auth=()
  url="$GITHUB_API_BASE/repos/$GH_REPO/releases/latest"
  tmp=$(mktemp)
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi
  if ! code=$(curl -sS -o "$tmp" -w '%{http_code}' "${auth[@]}" "$url"); then
    rm -f "$tmp"; return 1
  fi
  case "$code" in
    200) ;;
    404) rm -f "$tmp"; return 2 ;;
    *)   warn "GitHub API 返回 HTTP $code:"; cat "$tmp" >&2; rm -f "$tmp"; return 1 ;;
  esac
  grep -oP '"tag_name"\s*:\s*"\K[^"]+' "$tmp" | head -n1
  rm -f "$tmp"
}

append_env() {
  local env_file="${GITHUB_ENV:-$PWD/github.env}"
  printf '%s\n' "$1" >> "$env_file"
}

if [ "$SKIP_IF_RELEASED" = "1" ] && [ "$FORCE" = "0" ]; then
  command -v curl >/dev/null 2>&1 \
    || die "未找到 curl，请先安装（curl 供版本比对使用）"
  [ -n "$GH_REPO" ] \
    || die "--skip-if-released 需要 --repo owner/name 或 GITHUB_REPOSITORY 环境变量"

  aur_version=$(fetch_aur_version) || die "无法获取 AUR 最新版本（RPC API）"
  log "AUR 最新版本: $aur_version"

  release_tag=""
  rc=0
  release_tag=$(fetch_latest_release_tag) || rc=$?
  if [ "$rc" -eq 0 ]; then
    # 兼容 v7.2.7-1 / linux-tachyon-7.2.7-1 两种 tag 风格
    norm_tag=${release_tag#v}
    norm_tag=${norm_tag#"$AUR_PKG_NAME"-}
    if [ "$norm_tag" = "$aur_version" ]; then
      log "GitHub 最新 release（$release_tag）已是 $aur_version，跳过编译"
      append_env "TACHYON_SKIP=1"
      append_env "TACHYON_VERSION=$aur_version"
      [ -n "${GITHUB_ENV:-}" ] || log "变量已写入 $PWD/github.env 供本地调试"
      exit 0
    fi
    log "版本不一致（AUR: $aur_version / release: $release_tag），继续编译"
  elif [ "$rc" -eq 2 ]; then
    log "GitHub 仓库尚无 release，继续编译"
  else
    # 查询失败时宁可多编一次，也不让整个 workflow 失败
    warn "无法获取最新 release 信息，继续编译"
  fi
fi

### ── 2. 构建用户与依赖 ──────────────────────────────────────────
# makepkg 拒绝以 root 运行，而 Actions 容器默认是 root，需要临时构建用户
BUILD_USER=""
if [ "$(id -u)" -eq 0 ]; then
  BUILD_USER=builder
  if ! id -u "$BUILD_USER" >/dev/null 2>&1; then
    useradd -m "$BUILD_USER"
  fi
  EXTRA_PKGS=()
  if [ -n "$USE_LLVM_LTO" ]; then
    EXTRA_PKGS=(clang llvm lld)
  fi
  log "安装编译依赖（含系统更新）"
  pacman -Syu --noconfirm --needed \
    base-devel bc cpio curl gettext git libelf pahole perl python tar xz zstd \
    "${EXTRA_PKGS[@]}"
else
  command -v makepkg >/dev/null 2>&1 \
    || die "本机运行请先安装 base-devel 及 PKGBUILD 声明的 makedepends"
fi

### ── 3. 克隆 / 更新 AUR 仓库 ───────────────────────────────────
if [ ! -d "$BUILD_ROOT/.git" ]; then
  log "克隆 $AUR_REPO_URL"
  git clone "$AUR_REPO_URL" "$BUILD_ROOT"
else
  log "更新已有仓库 $BUILD_ROOT"
  git -C "$BUILD_ROOT" pull --ff-only
fi

### ── 4. 编译 ───────────────────────────────────────────────────
# makepkg.conf 里 MAKEFLAGS 默认被注释，不显式传入会单线程编译
MAKEPKG_ENV=(
  "MAKEFLAGS=-j$(nproc)"
  "_subarch=$SUBARCH"
  "_subarch_microarch=$SUBARCH_MICROARCH"
  "_debug=$DEBUG"
)
if [ -n "$USE_LLVM_LTO" ]; then
  MAKEPKG_ENV+=("_use_llvm_lto=y")
fi

log "开始编译（$(nproc) 线程），标准 runner（4 核）约需 1~3 小时"
cd "$BUILD_ROOT"
if [ -n "$BUILD_USER" ]; then
  chown -R "$BUILD_USER":"$BUILD_USER" "$BUILD_ROOT"
  # 依赖已由 root 预装，故不用 -s，构建用户无需配置 sudo
  runuser -u "$BUILD_USER" -- env HOME="/home/$BUILD_USER" \
    "${MAKEPKG_ENV[@]}" makepkg "${MAKEPKG_FLAGS[@]}"
else
  env "${MAKEPKG_ENV[@]}" makepkg "${MAKEPKG_FLAGS[@]}"
fi

### ── 5. 记录产物并写入 $GITHUB_ENV ──────────────────────────────
shopt -s nullglob
kernel_pkgs=( "$BUILD_ROOT"/linux-tachyon-[0-9]*-x86_64.pkg.tar.zst )
headers_pkgs=( "$BUILD_ROOT"/linux-tachyon-headers-*-x86_64.pkg.tar.zst )
all_pkgs=( "$BUILD_ROOT"/*.pkg.tar.zst )
shopt -u nullglob

[ ${#kernel_pkgs[@]} -gt 0 ]  || die "未找到 linux-tachyon 主包"
[ ${#headers_pkgs[@]} -gt 0 ] || die "未找到 linux-tachyon-headers 包"

kernel_name="$(basename "${kernel_pkgs[0]}")"
headers_name="$(basename "${headers_pkgs[0]}")"
version="${kernel_name#linux-tachyon-}"      # 6.16.1-1-x86_64.pkg.tar.zst
version="${version%-x86_64.pkg.tar.zst}"     # -> 6.16.1-1

log "编译完成，共 ${#all_pkgs[@]} 个包："
for p in "${all_pkgs[@]}"; do
  printf '    %s（%s）\n' "$(basename "$p")" "$(du -h "$p" | cut -f1)"
done

env_file="${GITHUB_ENV:-$PWD/github.env}"
{
  echo "TACHYON_VERSION=$version"
  echo "TACHYON_PKG_DIR=$BUILD_ROOT"
  echo "TACHYON_KERNEL_PKG=$kernel_name"
  echo "TACHYON_HEADERS_PKG=$headers_name"
  echo "TACHYON_ALL_PKGS<<__TACHYON_EOF__"
  for p in "${all_pkgs[@]}"; do
    basename "$p"
  done
  echo "__TACHYON_EOF__"
} >> "$env_file"

if [ -z "${GITHUB_ENV:-}" ]; then
  log "未检测到 GITHUB_ENV，变量已写入 $env_file 供本地调试"
fi
