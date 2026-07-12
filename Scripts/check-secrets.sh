#!/bin/bash
set -euo pipefail

patterns='(sk-ant-api[0-9A-Za-z_-]{20,}|sk-(proj-)?[0-9A-Za-z_-]{32,}|AIza[0-9A-Za-z_-]{24,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----)'

files=()
while IFS= read -r -d '' file; do
  [[ "$file" == "Scripts/check-secrets.sh" ]] || files+=("$file")
done < <(git ls-files --cached --others --exclude-standard -z)

if ((${#files[@]} > 0)) && grep -I -nE "$patterns" -- "${files[@]}"; then
  echo "Potential credential material found in version-controlled or untracked files." >&2
  exit 1
fi

echo "No common credential patterns found in candidate repository files."
