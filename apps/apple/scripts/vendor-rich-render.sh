#!/usr/bin/env bash
# Copies the web app's KaTeX and Mermaid builds into OmnigentUIComponents' RichRender resources,
# the offline page the transcript typesets math and draws diagrams with (never a CDN).
# Mermaid is stored LZMA-compressed (decompressed by RichBlockRenderer) to stay under the repo's
# 1 MB file limit. Run after `pnpm install` whenever the web app's katex or mermaid changes.
# Usage: vendor-rich-render.sh
set -euo pipefail

repo="$(cd "$(dirname "$0")/../../.." && pwd)"
store="$repo/node_modules/.pnpm"
out="$repo/apps/apple/Packages/OmnigentUI/Sources/OmnigentUIComponents/Resources/RichRender"

only_match() {
  local matches=("$store"/$1)
  if [[ ${#matches[@]} -ne 1 || ! -d "${matches[0]}" ]]; then
    echo "error: expected one $1 in $store, found: ${matches[*]}" >&2
    exit 1
  fi
  echo "${matches[0]}"
}

katex="$(only_match 'katex@*')/node_modules/katex"
mermaid="$(only_match 'mermaid@*')/node_modules/mermaid"

mkdir -p "$out/fonts"
rm -f "$out"/fonts/*
cp "$katex/dist/katex.min.js" "$katex/dist/katex.min.css" "$out/"
cp "$katex"/dist/fonts/*.woff2 "$out/fonts/"
cp "$katex/LICENSE" "$out/LICENSE-KaTeX.txt"
cp "$mermaid/LICENSE" "$out/LICENSE-mermaid.txt"
# The end-of-file hook wants a final newline on every text file.
for file in "$out"/katex.min.js "$out"/katex.min.css; do
  [[ -z "$(tail -c 1 "$file")" ]] || echo >>"$file"
done

compressor="$(mktemp -d)/compress.swift"
cat >"$compressor" <<'SWIFT'
import Foundation

let input = try Data(contentsOf: URL(filePath: CommandLine.arguments[1]))
let packed = try (input as NSData).compressed(using: .lzma) as Data
try packed.write(to: URL(filePath: CommandLine.arguments[2]))
SWIFT
swift "$compressor" "$mermaid/dist/mermaid.min.js" "$out/mermaid.min.js.lzma"
rm -rf "$(dirname "$compressor")"

katex_version="$(sed -n 's/^ *"version": "\(.*\)",$/\1/p' "$katex/package.json" | head -1)"
mermaid_version="$(sed -n 's/^ *"version": "\(.*\)",$/\1/p' "$mermaid/package.json" | head -1)"
printf 'katex %s\nmermaid %s\n' "$katex_version" "$mermaid_version" >"$out/VERSIONS.txt"
echo "vendored katex $katex_version and mermaid $mermaid_version into $out"
