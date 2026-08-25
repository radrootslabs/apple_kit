#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

dependency_url="https://github.com/21-DOT-DEV/swift-secp256k1.git"
dependency_revision="e70a10e036a55fffea31568f0af92d69b6d449cd"

test "$(grep -F -c "url: \"$dependency_url\"" Package.swift)" -eq 1
test "$(grep -F -c "revision: \"$dependency_revision\"" Package.swift)" -eq 1
test "$(grep -E -c '^[[:space:]]*\.package\(' Package.swift)" -eq 1
test "$(grep -F -c "\"location\" : \"$dependency_url\"" Package.resolved)" -eq 1
test "$(grep -F -c "\"revision\" : \"$dependency_revision\"" Package.resolved)" -eq 1

if grep -E -q '\.package\((path:|.*branch:|.*from:|.*exact:)' Package.swift; then
  echo "supply_chain_invalid: dependency must use only the governed immutable revision" >&2
  exit 1
fi

test "$(grep -F -c '"identity" : "swift-secp256k1"' Package.resolved)" -eq 1
test "$(grep -F -c '"identity" :' Package.resolved)" -eq 1
test "$(grep -F -c '"kind" : "remoteSourceControl"' Package.resolved)" -eq 1
grep -F -q 'GPL-3.0-or-later' README
grep -F -q 'GNU GENERAL PUBLIC LICENSE' LICENSE

echo "supply-chain ok: one immutable Swift dependency"
