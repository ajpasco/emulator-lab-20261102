#!/bin/sh
# Start an Android emulator headless on a GitHub-hosted Linux runner, exactly as the runner under test
# does, and keep its log. POSIX sh. EXTRA_EMU_ARGS adds emulator flags for a trial.
set -u
REPORT=report
BOOT_LIMIT_S=${BOOT_LIMIT_S:-600}
mkdir -p "$REPORT" || exit 1
say() { printf '[lab] %s\n' "$*"; }

SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
[ -n "$SDK" ] && [ -d "$SDK" ] || { say "neither ANDROID_HOME nor ANDROID_SDK_ROOT names the Android SDK"; exit 1; }
BIN=$SDK/cmdline-tools/latest/bin
ADB_TOOL=$SDK/platform-tools/adb
EMULATOR=$SDK/emulator/emulator
case "$(uname -m)" in arm64|aarch64) ABI=arm64-v8a ;; *) ABI=x86_64 ;; esac
installed() { [ -f "$SDK/$(printf '%s' "$1" | tr ';' '/')/source.properties" ]; }
sdk_install() { installed "$1" || yes 2>/dev/null | "$BIN/sdkmanager" --install "$1" >/dev/null; }
say "emulator present before install: $([ -x "$EMULATOR" ] && echo yes || echo no)"
[ -x "$ADB_TOOL" ] || sdk_install platform-tools || exit 1
[ -x "$EMULATOR" ] || sdk_install emulator || exit 1
[ -n "${INSTALL_EMULATOR:-}" ] && { yes 2>/dev/null | "$BIN/sdkmanager" --install emulator >/dev/null || exit 1; }
say "emulator source.properties:"; cat "$SDK/emulator/source.properties" 2>&1
IMAGE=${IMAGE:-"system-images;android-37.0;google_apis;$ABI"}
sdk_install "$IMAGE" || { say "could not install $IMAGE"; exit 1; }
say "image: $IMAGE"
say "image source.properties:"; cat "$SDK/$(printf '%s' "$IMAGE" | tr ';' '/')/source.properties" 2>&1
echo no | "$BIN/avdmanager" create avd --force -n aict -k "$IMAGE" >/dev/null || exit 1
say "config.ini:"; cat "$HOME/.android/avd/aict.avd/config.ini" 2>&1
port=5580
while "$ADB_TOOL" devices | grep -q "^emulator-$port[[:space:]]"; do
  port=$((port + 2)); [ "$port" -le 5680 ] || { say "no free emulator port"; exit 1; }
done
ADB=$ADB_TOOL; SERIAL=emulator-$port
ANDROID_SERIAL=$SERIAL; export ANDROID_SERIAL
say "starting at $(date -u +%T) with extra args: ${EXTRA_EMU_ARGS:-none}"
# shellcheck disable=SC2086
"$EMULATOR" -avd aict -port "$port" -no-window -no-audio -no-boot-anim -no-snapshot ${EXTRA_EMU_ARGS:-} > "$REPORT/emulator.log" 2>&1 &
EMU_PID=$!
end=$(( $(date +%s) + BOOT_LIMIT_S )); booted=0
while [ "$(date +%s)" -lt "$end" ]; do
  kill -0 "$EMU_PID" 2>/dev/null || { wait "$EMU_PID"; say "the emulator exited at $(date -u +%T) with status $?"; break; }
  if [ "$("$ADB" -s "$SERIAL" get-state 2>/dev/null)" = device ] &&
     [ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then
    booted=1; break
  fi
  sleep 5
done
[ "$booted" = 1 ] || { say "the emulator did not boot within $BOOT_LIMIT_S seconds"; exit 1; }
say "booted after $(( BOOT_LIMIT_S - (end - $(date +%s)) )) seconds"
"$ADB" -s "$SERIAL" shell getprop ro.build.version.sdk
"$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1
exit 0
