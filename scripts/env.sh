# G2 Mobile toolchain environment. Source it (do not execute):
#     source g2-mobile/scripts/env.sh
# Everything lives under ~/sdk (no system packages, no shell-rc edits).
export G2_SDK_ROOT="${G2_SDK_ROOT:-$HOME/sdk}"
export JAVA_HOME="$G2_SDK_ROOT/jdk"
export ANDROID_HOME="$G2_SDK_ROOT/android"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export FLUTTER_ROOT="$G2_SDK_ROOT/flutter"
export PUB_CACHE="${PUB_CACHE:-$HOME/.pub-cache}"
case ":$PATH:" in
  *":$FLUTTER_ROOT/bin:"*) ;;
  *) export PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$FLUTTER_ROOT/bin:$PATH" ;;
esac
# Opt out of analytics for non-interactive builds.
export FLUTTER_SUPPRESS_ANALYTICS=true
