#!/bin/zsh
# Sweep 2b · 4.5 — compile + run the headless disk-cache check (no app, no Simulator). Output under build/4x/.
ROOT=${0:A:h:h:h:h:h}; O=$ROOT/build/4x/disk-cache-test; mkdir -p $O
cp ${0:A:h}/disk_cache_test.swift $O/main.swift
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O -o $O/disk_cache_test \
  $ROOT/AirPad/Services/DisplayImageDiskCache.swift $O/main.swift || exit 2
$O/disk_cache_test
