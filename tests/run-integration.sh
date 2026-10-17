#!/usr/bin/env bash
# Интеграционная проверка на настоящем дистрибутиве 1С (локально, не в CI).
#
#   tests/run-integration.sh ~/Downloads/training_8_3_27_1508_LinuxRun.tar.gz
#   tests/run-integration.sh ~/Downloads/server64_8_3_27_2130.tar.gz client_full server
#
# Аргументы после архива — components (по умолчанию client_full).
# Берутся отслеживаемые git файлы репозитория (git+file), а не весь каталог:
# архивы дистрибутивов рядом не копируются в стор.
set -euo pipefail

file="$(realpath "${1:?укажите путь к архиву дистрибутива}")"
shift
repo="$(cd "$(dirname "$0")/.." && pwd)"

comps="client_full"
[ "$#" -eq 0 ] || comps="$*"

nix store add --mode flat "$file" >/dev/null
hash="$(nix hash file "$file")"

# Значения — через --argstr, а не подстановкой в код Nix.
exec nix build --no-link --print-build-logs --impure \
  --argstr repo "$repo" \
  --argstr name "$(basename "$file")" \
  --argstr hash "$hash" \
  --argstr comps "$comps" \
  --expr '
    { repo, name, hash, comps }:
    let
      onec = builtins.getFlake "git+file://${repo}";
      pkgs = import onec.inputs.nixpkgs {
        system = "x86_64-linux";
        config.allowUnfree = true;
      };
    in
    onec.lib.mkIntegrationTest pkgs (onec.lib.mkOnec pkgs {
      src = onec.lib.requireDist pkgs { inherit name hash; };
      components = builtins.filter (c: builtins.isString c && c != "") (builtins.split " +" comps);
    })
  '
