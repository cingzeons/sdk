#!/usr/bin/env bash
# Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
# for details. All rights reserved. Use of this source code is governed by a
# BSD-style license that can be found in the LICENSE file.

# Compile flutter tests with a locally built SDK.

set -e

checkout=$(pwd)
dart=$checkout/out/ReleaseX64/dart-sdk/bin/dart
sdk=$checkout/out/ReleaseX64/dart-sdk
tmpdir=$(mktemp -d)
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT HUP INT QUIT TERM PIPE
pushd "$tmpdir"

git clone -vv https://chromium.googlesource.com/external/github.com/flutter/flutter

pushd flutter
bin/flutter config --no-analytics
pinned_dart_sdk=$(cat bin/cache/dart-sdk/revision)
patch=$checkout/tools/patches/flutter-engine/${pinned_dart_sdk}.flutter.patch
if [ -e "$patch" ]; then
  git apply $patch
fi
bin/flutter update-packages
popd

# Directly in temp directory again.
mkdir engine
pushd engine
git clone -vv --depth 1 https://chromium.googlesource.com/external/github.com/flutter/engine flutter
mkdir third_party
pushd third_party
ln -s $checkout dart
popd
popd

mkdir flutter_patched_sdk

$checkout/tools/sdks/dart-sdk/bin/dart --packages=$checkout/.packages $checkout/pkg/front_end/tool/_fasta/compile_platform.dart dart:core --single-root-scheme=org-dartlang-sdk --single-root-base=$checkout/ org-dartlang-sdk:///sdk/lib/libraries.json vm_outline_strong.dill vm_platform_strong.dill vm_outline_strong.dill
$checkout/tools/sdks/dart-sdk/bin/dart --packages=$checkout/.packages $checkout/pkg/front_end/tool/_fasta/compile_platform.dart --target=flutter dart:core --single-root-scheme=org-dartlang-sdk --single-root-base=engine org-dartlang-sdk:///flutter/lib/snapshot/libraries.json vm_outline_strong.dill flutter_patched_sdk/platform_strong.dill flutter_patched_sdk/outline_strong.dill

popd

$dart --enable-asserts pkg/vm/test/frontend_server_flutter.dart --flutterDir=$tmpdir/flutter --flutterPlatformDir=$tmpdir/flutter_patched_sdk
