# Sourced by every build/test script. The macOS 27 Command Line Tools SDK declares
# SwiftUI's @State/@Observable as macros whose SwiftUIMacros plugin ships only inside
# Xcode, so when the active developer dir lacks it, point this process (never the
# global xcode-select) at Xcode.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  _active=$(xcode-select -p 2>/dev/null)
  if [[ ! -e "$_active/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" \
        && ! -e "$_active/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]]; then
    for _xcode in /Applications/Xcode.app /Applications/Xcode-beta.app; do
      if [[ -d "$_xcode/Contents/Developer" ]]; then
        export DEVELOPER_DIR="$_xcode/Contents/Developer"
        break
      fi
    done
  fi
  unset _active _xcode
fi
# SwiftLint loads sourcekitd from the selected toolchain.
if [[ -z "${TOOLCHAIN_DIR:-}" ]]; then
  _developer=${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null)}
  if [[ -d "$_developer/Toolchains/XcodeDefault.xctoolchain" ]]; then
    export TOOLCHAIN_DIR="$_developer/Toolchains/XcodeDefault.xctoolchain"
  fi
  unset _developer
fi
# Periphery from scripts/install-periphery.sh, ahead of any other copy.
if [[ -x .build/tools/periphery/periphery && ":$PATH:" != *":$PWD/.build/tools/periphery:"* ]]; then
  export PATH="$PWD/.build/tools/periphery:$PATH"
fi
