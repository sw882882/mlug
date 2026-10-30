#!/bin/sh
# Dev loop: build + install the tablet app, then run the Mac side from the terminal.
#   ./run.sh            build everything, install APK, start streaming
#   ./run.sh --no-apk   skip the Android build/install
set -e
cd "$(dirname "$0")"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"

if [ "$1" != "--no-apk" ]; then
    (cd android && ./gradlew -q assembleDebug)
    adb install -r android/app/build/outputs/apk/debug/app-debug.apk
else
    shift
fi
(cd mac && swift build -c release --product mlug)
exec mac/.build/release/mlug "$@"
