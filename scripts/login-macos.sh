#!/bin/sh
set -eu
label=local.anykeymic
plist="$HOME/Library/LaunchAgents/$label.plist"
if [ "${1:-}" = "--remove" ]; then
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    rm -f "$plist"
    exit 0
fi
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bin_dir=$(swift build -c release --scratch-path build --show-bin-path | tail -n 1)
source_binary="$bin_dir/anykey-mic"
test -x "$source_binary" || { echo '请先执行 swift build -c release --scratch-path build。'; exit 1; }
binary="$HOME/Library/Application Support/AnyKeyMic/anykey-mic"
mkdir -p "$(dirname "$binary")"
cp "$source_binary" "$binary"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/AnyKeyMic"
# 使用 plutil 设置字符串，正确处理路径内的 XML 特殊字符。
plutil -create xml1 "$plist"
plutil -insert Label -string "$label" "$plist"
plutil -insert ProgramArguments -json '["run"]' "$plist"
plutil -insert ProgramArguments.0 -string "$binary" "$plist"
plutil -insert RunAtLoad -bool YES "$plist"
plutil -insert KeepAlive -bool YES "$plist"
plutil -insert ThrottleInterval -integer 15 "$plist"
plutil -insert StandardErrorPath -string "$HOME/Library/Logs/AnyKeyMic/run.log" "$plist"
launchctl bootstrap "gui/$(id -u)" "$plist"
