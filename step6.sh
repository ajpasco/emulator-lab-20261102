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
case "${AVD_HOME_MODE:-}" in
  env) ANDROID_AVD_HOME=${ANDROID_AVD_HOME:-$HOME/.android/avd}; export ANDROID_AVD_HOME
       mkdir -p "$ANDROID_AVD_HOME" || exit 1; say "ANDROID_AVD_HOME=$ANDROID_AVD_HOME" ;;
  mkdir) mkdir -p "$HOME/.android" || exit 1; say "made $HOME/.android first" ;;
esac
say "command-line tools on the image: $(grep Pkg.Revision "$SDK/cmdline-tools/latest/source.properties" 2>&1)"
say "environment: $(env | grep -E '^(HOME|XDG_[A-Z_]*|ANDROID_[A-Z_]*)=' | sort | tr '\n' ' ')"
if [ -n "${CLT_VERSION:-}" ]; then
  yes 2>/dev/null | "$BIN/sdkmanager" --install "cmdline-tools;$CLT_VERSION" >/dev/null || { say "could not install cmdline-tools;$CLT_VERSION"; exit 1; }
  BIN=$SDK/cmdline-tools/$CLT_VERSION/bin
  say "using command-line tools $(grep Pkg.Revision "$SDK/cmdline-tools/$CLT_VERSION/source.properties" 2>&1) from $BIN"
fi
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
echo no | "$BIN/avdmanager" create avd --force -n aict -k "$IMAGE" > "$REPORT/avdmanager.log" 2>&1; st=$?
say "avdmanager create avd exited $st; its output:"; tr '\r' '\n' < "$REPORT/avdmanager.log" | grep -v '^\s*$' | tail -20
[ "$st" = 0 ] || exit 1
say "where aict.ini is:"; find / -xdev -name aict.ini 2>/dev/null | head
say "avdmanager list avd:"; "$BIN/avdmanager" list avd 2>&1 | tail -8
say "emulator -list-avds:"; "$EMULATOR" -list-avds 2>&1 | tail -5
say "config.ini:"; cat "${ANDROID_AVD_HOME:-$HOME/.android/avd}/aict.avd/config.ini" 2>&1 | head -40
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
