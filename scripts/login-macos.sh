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

unload() {
    if launchctl print "$service" >/dev/null 2>&1; then launchctl bootout "$service"; fi
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
    root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
    bin_dir=$(cd "$root" && swift build -c release --scratch-path build --show-bin-path | tail -n 1)
    source_binary="$bin_dir/anykey-mic"
    test -x "$source_binary" || { echo '请先成功构建 anykey-mic。' >&2; exit 1; }
    mkdir -p "$app_dir"
    test -f "$app_dir/config.json" || { echo '请先执行 configure 配置虚拟声卡。' >&2; exit 1; }
    unload
    cp "$source_binary" "$binary"
    write_plist
    unload
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

command=${1:-install}
case "$command" in
    install) install_service ;;
    uninstall|remove) uninstall_service ;;
    start) start_service ;;
    stop) stop_service ;;
    restart) stop_service; start_service ;;
    status) status_service ;;
    --remove) uninstall_service ;;
    *) echo "用法：$0 {install|uninstall|start|stop|restart|status}" >&2; exit 2 ;;
esac
