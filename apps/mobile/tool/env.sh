# Source this before any flutter or gradle command in this app:
#   source tool/env.sh
#
# Values already set in the environment win. The macOS paths below are only
# fallbacks for a default Android Studio install. Put machine-specific
# overrides in tool/env.local.sh (git-ignored); it is sourced first.

_app_tool_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [ -f "$_app_tool_dir/env.local.sh" ]; then
  # shellcheck disable=SC1091
  . "$_app_tool_dir/env.local.sh"
fi

# JDK 17 or newer. Fallback: the JetBrains Runtime bundled with Android Studio.
if [ -z "${JAVA_HOME:-}" ]; then
  for _jdk in \
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
    "$HOME/android-studio/jbr" \
    "/opt/android-studio/jbr"; do
    if [ -d "$_jdk" ]; then export JAVA_HOME="$_jdk"; break; fi
  done
fi

# Android SDK. ANDROID_SDK_ROOT is accepted as an alias.
if [ -z "${ANDROID_HOME:-}" ]; then
  if [ -n "${ANDROID_SDK_ROOT:-}" ]; then
    export ANDROID_HOME="$ANDROID_SDK_ROOT"
  elif [ -d "$HOME/Library/Android/sdk" ]; then
    export ANDROID_HOME="$HOME/Library/Android/sdk"
  elif [ -d "$HOME/Android/Sdk" ]; then
    export ANDROID_HOME="$HOME/Android/Sdk"
  fi
fi
if [ -n "${ANDROID_HOME:-}" ]; then
  export PATH="$ANDROID_HOME/platform-tools:$PATH"
fi

# Flutter: the version pinned in .fvmrc. With FVM installed, use `fvm flutter`
# (the Makefile does this). Without FVM, put the FVM cache of that version on
# PATH when it exists, else rely on the `flutter` already on PATH.
_flutter_version="$(sed -n 's/.*"flutter"[^"]*"\([^"]*\)".*/\1/p' "$_app_tool_dir/../.fvmrc" 2>/dev/null)"
if [ -n "${FLUTTER_ROOT:-}" ]; then
  export PATH="$FLUTTER_ROOT/bin:$PATH"
elif ! command -v fvm >/dev/null 2>&1 && [ -n "$_flutter_version" ] \
  && [ -d "$HOME/fvm/versions/$_flutter_version/bin" ]; then
  export PATH="$HOME/fvm/versions/$_flutter_version/bin:$PATH"
fi

unset _app_tool_dir _jdk _flutter_version
