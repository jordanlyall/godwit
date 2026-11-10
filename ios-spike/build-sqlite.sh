#!/bin/bash
# Builds mygo's SQLite plugin library (libmygo-sqlite3) for iOS as MygoSQLite.xcframework.
# mygo ships no iOS slice; this mirrors plugins/sqlite/native/build.zig with Xcode clang.
# usage: ios-spike/build-sqlite.sh <dir with verified sqlite3.c/sqlite3.h, SQLite 3.53.4>
# Refuses to overwrite: remove ios-spike/build-sqlite and ios-spike/MygoSQLite.xcframework first.
set -euo pipefail
src="$1"; here="$(cd "$(dirname "$0")" && pwd)"
shim="$(cd "$here/.." && go list -m -f '{{.Dir}}' github.com/egoist/mygo)/plugins/sqlite/native/sqlite.c"
out="$here/build-sqlite"
if [ -e "$out" ] || [ -e "$here/MygoSQLite.xcframework" ]; then echo "old output exists; remove it first" >&2; exit 1; fi
defs=(-DSQLITE_THREADSAFE=1 -DSQLITE_DQS=0 -DSQLITE_DEFAULT_FOREIGN_KEYS=1 -DSQLITE_ENABLE_FTS5=1
      -DSQLITE_ENABLE_RTREE=1 -DSQLITE_OMIT_LOAD_EXTENSION=1 -DSQLITE_OMIT_DEPRECATED=1 -DSQLITE_OMIT_SHARED_CACHE=1)
build() { # sdk target-triple dir
  local fw="$out/$3/MygoSQLite.framework"; mkdir -p "$fw"
  xcrun --sdk "$1" clang -target "$2" -isysroot "$(xcrun --sdk "$1" --show-sdk-path)" -std=c11 -O2 -fPIC \
    "${defs[@]}" -I "$src" "$src/sqlite3.c" "$shim" -dynamiclib -Wl,-x \
    -install_name @rpath/MygoSQLite.framework/MygoSQLite -o "$fw/MygoSQLite"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.jordanlyall.mygosqlite" \
    -c "Add :CFBundleName string MygoSQLite" -c "Add :CFBundleExecutable string MygoSQLite" \
    -c "Add :CFBundlePackageType string FMWK" -c "Add :CFBundleVersion string 3.53.4" \
    -c "Add :CFBundleShortVersionString string 3.53.4" -c "Add :MinimumOSVersion string 17.0" "$fw/Info.plist" >/dev/null
}
build iphoneos arm64-apple-ios17.0 device
build iphonesimulator arm64-apple-ios17.0-simulator sim
xcodebuild -create-xcframework -framework "$out/device/MygoSQLite.framework" -framework "$out/sim/MygoSQLite.framework" \
  -output "$here/MygoSQLite.xcframework" >/dev/null
echo "built $here/MygoSQLite.xcframework"
