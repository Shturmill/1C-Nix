#!/usr/bin/env bash
# Интеграционная проверка на настоящем дистрибутиве 1С (локально, не в CI).
#
#   tests/run-integration.sh ~/Downloads/training_8_3_27_1508_LinuxRun.tar.gz
#   tests/run-integration.sh ~/Downloads/server64_8_3_27_2130.tar.gz client_full server
#
# Аргументы после архива — components (по умолчанию client_full).
set -euo pipefail

file="$(realpath "${1:?укажите путь к архиву дистрибутива}")"
shift
repo="$(cd "$(dirname "$0")/.." && pwd)"
name="$(basename "$file")"

comps="client_full"
[ "$#" -eq 0 ] || comps="$*"
nixComps="$(printf '"%s" ' $comps)"

nix store add --mode flat "$file" >/dev/null
hash="$(nix hash file "$file")"

exec nix build --no-link --print-build-logs --impure --expr "
  let
    onec = builtins.getFlake \"path:$repo\";
    pkgs = import onec.inputs.nixpkgs {
      system = \"x86_64-linux\";
      config.allowUnfree = true;
    };
  in
  onec.lib.mkIntegrationTest pkgs (onec.lib.mkOnec pkgs {
    src = onec.lib.requireDist pkgs { name = \"$name\"; hash = \"$hash\"; };
    components = [ $nixComps ];
  })
"
