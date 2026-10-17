#!/bin/sh
set -eu

label=local.anykeymic
domain="gui/$(id -u)"
service="$domain/$label"
plist="$HOME/Library/LaunchAgents/$label.plist"
app_dir="$HOME/Library/Application Support/AnyKeyMic"
binary="$app_dir/anykey-mic"
log_dir="$HOME/Library/Logs/AnyKeyMic"
log_file="$log_dir/run.log"
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

usage() {
    cat <<EOF
用法：$0 <命令>
  devices              列出输出设备
  configure <序号>      绑定 devices 列出的虚拟声卡
  keymap [none]        交互捕获 AI 键映射的目标按键；none 清除映射
  install              构建、安装并启动登录自启服务
  uninstall            卸载登录自启服务，保留配置与日志
  start | stop | restart | status
设置 ANYKEYMIC_SIGN_IDENTITY 为证书名称后，install 会用它签名，重新构建后无需再次授权输入监控。
EOF
}

build() {
    (cd "$root" && swift build -c release --scratch-path build >&2)
    built_binary="$(cd "$root" && swift build -c release --scratch-path build --show-bin-path | tail -n 1)/anykey-mic"
    test -x "$built_binary" || { echo '请先成功构建 anykey-mic。' >&2; exit 1; }
}

unload() {
    launchctl print "$service" >/dev/null 2>&1 || return 0
    launchctl bootout "$service" || true
    # bootout 返回时服务可能仍在退出，立即 bootstrap 会报 5: Input/output error。
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        launchctl print "$service" >/dev/null 2>&1 || return 0
        sleep 0.5
    done
    echo "服务 $label 未能在 10 秒内退出。" >&2
    exit 1
}

write_plist() {
    mkdir -p "$app_dir" "$(dirname "$plist")" "$log_dir"
    plutil -create xml1 "$plist"
    plutil -insert Label -string "$label" "$plist"
    plutil -insert ProgramArguments -json '["run"]' "$plist"
    plutil -insert ProgramArguments.0 -string "$binary" "$plist"
    plutil -insert RunAtLoad -bool YES "$plist"
    plutil -insert KeepAlive -bool YES "$plist"
    plutil -insert ThrottleInterval -integer 15 "$plist"
    plutil -insert StandardOutPath -string "$log_file" "$plist"
    plutil -insert StandardErrorPath -string "$log_file" "$plist"
}

install_service() {
    test -f "$app_dir/config.json" || { echo '请先执行 configure 配置虚拟声卡。' >&2; exit 1; }
    build
    unload
    cp "$built_binary" "$binary"
    if [ -n "${ANYKEYMIC_SIGN_IDENTITY:-}" ]; then
        codesign -f -s "$ANYKEYMIC_SIGN_IDENTITY" -i "$label" "$binary"
    else
        # 临时签名按文件哈希授权，每次覆盖程序后都要重新授予输入监控。
        echo "提示：程序为临时签名，需在「系统设置 › 隐私与安全性 › 输入监控」中重新允许：$binary"
    fi
    write_plist
    launchctl bootstrap "$domain" "$plist"
    launchctl kickstart "$service"
    echo "已安装并启动登录自启服务：$label"
    echo "日志：$log_file"
}

start_service() {
    test -f "$plist" || { echo '服务尚未安装，请先执行 install。' >&2; exit 1; }
    if ! launchctl print "$service" >/dev/null 2>&1; then
        launchctl bootstrap "$domain" "$plist"
    fi
    launchctl kickstart "$service"
    echo '服务已启动。'
}

stop_service() {
    if launchctl print "$service" >/dev/null 2>&1; then
        unload
    else
        echo '服务当前未运行。'
    fi
}

status_service() {
    if [ -f "$plist" ]; then echo '已安装：是'; else echo '已安装：否'; fi
    launchctl print "$service" 2>/dev/null || echo '运行状态：未加载'
    echo "程序：$binary"
    echo "日志：$log_file"
}

uninstall_service() {
    unload
    rm -f "$plist"
    echo '已卸载登录自启服务，配置、运行文件与日志已保留。'
}

command=${1:-help}
case "$command" in
    devices|configure|keymap) build; exec "$built_binary" "$@" ;;
    install) install_service ;;
    uninstall|remove|--remove) uninstall_service ;;
    start) start_service ;;
    stop) stop_service ;;
    restart) stop_service; start_service ;;
    status) status_service ;;
    help|-h|--help) usage ;;
    *) usage >&2; exit 2 ;;
esac
