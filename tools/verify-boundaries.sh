#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

for forbidden_root in docs .github .act; do
  test ! -e "$forbidden_root"
  test ! -L "$forbidden_root"
done

if git ls-files | grep -E -i '(^|/)(\.env|id_rsa|id_ed25519|credentials|[^/]+\.(pem|key|p12|pfx|jks|keystore))$' >/dev/null; then
  echo "boundary_invalid: sensitive credential path is tracked" >&2
  exit 1
fi
if git grep -I -n -E -e '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{36,}|nsec1[023456789acdefghjklmnpqrstuvwxyz]{40,}' -- Sources >/dev/null; then
  echo "boundary_invalid: production source contains credential material" >&2
  exit 1
fi
if git grep -I -n -E \
  -e 'localizedDescription' \
  -e 'public let errorMessage: String' \
  -e 'case rejected\(code: String\)' \
  -e 'case (invalidRequest|unavailable|permissionDenied|userCancelled|transientFailure|permanentFailure|transferFailure|persistenceFailure|notFound|blockedByPolicy|timeout|cancelled|schedulerFailure|preparationFailure|keychainStatus)\([^)]*String' \
  -- Sources >/dev/null; then
  echo "boundary_invalid: public error surface accepts arbitrary diagnostic text" >&2
  exit 1
fi

swift build
bin_path="$(swift build --show-bin-path)"
arch="$(swift -print-target-info | sed -n 's/.*"arch": "\([^"]*\)".*/\1/p')"
test -n "$arch"
sdk_path="$(xcrun --show-sdk-path --sdk macosx)"
module_map="$bin_path/libsecp256k1.build/module.modulemap"
dependency_include="$repo_root/.build/checkouts/swift-secp256k1/Sources/libsecp256k1/include"
test -f "$module_map"
test -d "$dependency_include"

temporary_dir="$(mktemp -d)"
temporary_api="$temporary_dir/apple_kit.txt"
trap 'rm -rf "$temporary_dir"' EXIT

for module in RadrootsKit RadrootsKitTesting; do
  xcrun swift-symbolgraph-extract \
    -module-name "$module" \
    -target "$arch-apple-macosx15.0" \
    -sdk "$sdk_path" \
    -I "$bin_path/Modules" \
    -Xcc "-fmodule-map-file=$module_map" \
    -Xcc -I \
    -Xcc "$dependency_include" \
    -minimum-access-level public \
    -skip-synthesized-members \
    -skip-inherited-docs \
    -omit-extension-block-symbols \
    -pretty-print \
    -output-dir "$temporary_dir"
done

swift tools/normalize-public-api.swift "$temporary_dir"/*.symbols.json >"$temporary_api"
cmp "$temporary_api" contracts/api_baselines/apple_kit.txt

echo "boundary ok: exact Swift API, no forbidden or credential surface"
