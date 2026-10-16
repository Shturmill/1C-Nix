# Проверки без настоящего дистрибутива 1С: вместо него — фальшивые архивы
# той же структуры. Так CI может гонять всю обвязку, ничего не нарушая.
#
# Фальшивый инсталлятор повторяет то, что наблюдалось у настоящего
# (setup-training-8.3.27.1508-x86_64.run, InstallBuilder 20.9):
#   * --prefix в --help нет; с ним postinst ломается — здесь сразу ошибка;
#   * ставит по зашитым путям /opt/1cv8{,t}/...;
#   * симлинки делает внешним `ln` из PATH;
#   * postinst — скрипт на #!/bin/bash, переносит 1cestart в common/;
#   * список компонентов печатает в --help строкой «Разрешено: …».
# Проверка на настоящем дистрибутиве — tests/integration.nix.
{
  pkgs,
  nixpkgs,
  self,
}:

let
  inherit (pkgs) lib runCommand;

  mkFakeInstaller =
    {
      version,
      top ? "1cv8",
      allowed,
    }:
    let
      t = lib.optionalString (top == "1cv8t") "t";
    in
    pkgs.writeScript "fake-setup.run" ''
      #!/bin/sh
      set -eu
      comps=""; disabled=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --help)
            printf '%s\n' \
              ' --enable-components <enable-components>     Comma-separated list of components' \
              '                                             По умолчанию: client_full,ws,ru' \
              '                                             Разрешено: ${allowed}' \
              "" \
              ' --disable-components <disable-components>   Comma-separated list of components'
            exit 0 ;;
          --prefix)
            echo "Невозможно создать символическую ссылку $2/opt/${top}/..." >&2
            exit 1 ;;
          --enable-components) comps="$2"; shift ;;
          --disable-components) disabled="$2"; shift ;;
        esac
        shift
      done
      [ "$(id -u)" = 0 ] || { echo "fake installer: нужен root" >&2; exit 3; }
      command -v ln >/dev/null || { echo "fake installer: нет ln в PATH" >&2; exit 4; }

      d=/opt/${top}/x86_64/${version}
      mkdir -p "$d"
      mk() {
        printf '#!/bin/sh\necho "fake %s $*"\necho "preload=''${LD_PRELOAD:-}"\nls /usr/lib/libgtk-3.so.0 >/dev/null 2>&1 && echo fhs-ok\nexit 0\n' "$1" > "$d/$1"
        chmod +x "$d/$1"
      }
      for c in $(echo "$comps" | tr , ' '); do
        case "$c" in
          client_thin) mk 1cv8c${t}; mk 1cestart${t} ;;
          client_full) mk 1cv8${t}; mk 1cv8c${t}; mk 1cestart${t} ;;
          server) mk ragent; mk rphost; mk rmngr; mk ibsrv ;;
          server_admin) mk ras; mk rac ;;
        esac
      done
      echo old > "$d/libstdc++.so.6.0.28"
      ln -s libstdc++.so.6.0.28 "$d/libstdc++.so.6"
      echo wk40 > "$d/libwx_gtk3u-3.0.so.0.1.0"
      echo wk41 > "$d/libwx_gtk3u-3.0.so.0.1.0.wk41"
      ln -s libwx_gtk3u-3.0.so.0.1.0 "$d/libwx_gtk3u-3.0.so.0"
      echo ext40 > "$d/webkit2_extu-3.0.so"
      echo ext41 > "$d/webkit2_extu-3.0.so.wk41"
      mkdir -p "$d/webkit2ext"
      ln -s ../webkit2_extu-3.0.so "$d/webkit2ext/webkit2_extu-3.0.so"
      echo "$comps" > "$d/installed-components"
      echo "$disabled" > "$d/disabled-components"
      touch "$d/uninstaller-fake" "$d/uninstaller-fake.dat"

      cat > "$d/postinst" <<EOF
      #!/bin/bash -e
      mkdir -p /opt/${top}/common /opt/${top}/conf
      [ -f /opt/${top}/conf/conf.cfg ] || echo SystemLanguage=System > /opt/${top}/conf/conf.cfg
      if [ -f $d/1cestart${t} ]; then
        mv $d/1cestart${t} /opt/${top}/common/
        echo "[Desktop Entry]" > /usr/share/applications/1cestart${t}.desktop
      fi
      EOF
      chmod +x "$d/postinst"
      "$d/postinst"
      rm "$d/postinst"
    '';

  mkTarball =
    {
      name,
      runName,
      installer,
    }:
    runCommand name { } ''
      mkdir dist
      cp ${installer} dist/${runName}
      chmod +x dist/*.run
      tar -czf "$out" -C dist .
    '';

  fakeVersion = "8.3.99.1";
  installerTarball = mkTarball {
    name = "server64_8_3_99_1.tar.gz";
    runName = "setup-full-${fakeVersion}-x86_64.run";
    installer = mkFakeInstaller {
      version = fakeVersion;
      allowed = "client_full client_thin server server_admin ws ru en";
    };
  };

  trainingVersion = "8.3.99.2";
  trainingTarball = mkTarball {
    name = "training_8_3_99_2_LinuxRun.tar.gz";
    runName = "setup-training-${trainingVersion}-x86_64.run";
    installer = mkFakeInstaller {
      version = trainingVersion;
      top = "1cv8t";
      allowed = "client_full v8_install_deps desktop_icons ws ru en";
    };
  };

  # Старый формат: tar.gz с .deb, раскладка /opt/1C/v8.3/x86_64.
  debTarball = runCommand "deb64_8_3_12_1855.tar.gz" { nativeBuildInputs = [ pkgs.dpkg ]; } ''
    mkdir -p pkg/DEBIAN pkg/opt/1C/v8.3/x86_64
    cat > pkg/DEBIAN/control <<EOF
    Package: 1c-enterprise83-client
    Version: 8.3.12-1855
    Architecture: amd64
    Maintainer: test
    Description: fake
    EOF
    printf '#!/bin/sh\necho fake-legacy\n' > pkg/opt/1C/v8.3/x86_64/1cv8c
    chmod +x pkg/opt/1C/v8.3/x86_64/1cv8c
    dpkg-deb --root-owner-group --build pkg 1c-enterprise83-client_8.3.12-1855_amd64.deb
    tar -czf "$out" *.deb
  '';

  onecFromInstaller = self.lib.mkOnec pkgs {
    src = installerTarball;
    components = [
      "client_thin"
      "server"
    ];
  };

  onecServerOnly = self.lib.mkOnec pkgs {
    src = installerTarball;
    components = [
      "server"
      "server_admin"
    ];
  };

  onecTraining = self.lib.mkOnec pkgs {
    src = trainingTarball;
    scale = 1.25;
  };

  # Сервера в учебной версии нет — сборка должна упасть с понятной ошибкой.
  onecTrainingServer = self.lib.mkOnec pkgs {
    src = trainingTarball;
    components = [
      "client_full"
      "server"
    ];
  };

  onecLegacy = self.lib.mkOnec pkgs { src = debTarball; };

  mkSystem =
    onecCfg:
    nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        self.nixosModules.default
        {
          nixpkgs.config.allowUnfree = true;
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          system.stateVersion = "26.05";
          users.users.alice.isNormalUser = true;
          services.onec = {
            enable = true;
          }
          // onecCfg;
        }
      ];
    };

  mcfg =
    (mkSystem {
      src = installerTarball;
      client.enable = true;
      server = {
        enable = true;
        openFirewall = true;
      };
      ras.enable = true;
      licensesDir.users = [ "alice" ];
    }).config;

  tcfg =
    (mkSystem {
      src = trainingTarball;
      client.enable = true;
    }).config;

  tcfgServer =
    (mkSystem {
      src = trainingTarball;
      server.enable = true;
    }).config;

  failedAssertions = c: map (a: a.message) (lib.filter (a: !a.assertion) c.assertions);

  closure = drv: pkgs.closureInfo { rootPaths = [ drv ]; };
in
{
  # Версия из имени файла, раскладка, правки поставки, обёртки.
  installer = runCommand "onec-test-installer" { } ''
    set -eu
    p=${onecFromInstaller}
    o=${onecFromInstaller.dist}/opt/1cv8
    d=$o/x86_64/${fakeVersion}

    [ "${onecFromInstaller.version}" = "${fakeVersion}" ]
    [ "${onecFromInstaller.optName}" = 1cv8 ]
    # язык добавлен сам, остальное явно отключено
    grep -qx 'client_thin,server,ru' "$d/installed-components"
    grep -qx 'client_full,server_admin,ws,en' "$d/disabled-components"

    for b in 1cv8c ragent rphost 1cestart onec-shell; do
      [ -x "$p/bin/$b" ] || { echo "нет обёртки $b" >&2; exit 1; }
    done
    [ ! -e "$p/bin/1cv8" ] || { echo "лишняя обёртка 1cv8" >&2; exit 1; }

    # postinst отработал: стартер в common/, conf.cfg создан
    [ -x "$o/common/1cestart" ] && [ ! -e "$d/1cestart" ]
    grep -q SystemLanguage "$o/conf/conf.cfg"

    [ ! -e "$d/libstdc++.so.6" ] && [ ! -e "$d/libstdc++.so.6.0.28" ] \
      || { echo "бандловый libstdc++ не удалён" >&2; exit 1; }
    [ ! -e "$d/uninstaller-fake" ] || { echo "uninstaller не удалён" >&2; exit 1; }
    [ "$(readlink "$d/libwx_gtk3u-3.0.so.0.1.0")" = libwx_gtk3u-3.0.so.0.1.0.wk41 ]
    [ "$(cat "$d/libwx_gtk3u-3.0.so.0")" = wk41 ]
    [ "$(cat "$d/webkit2ext/webkit2_extu-3.0.so")" = ext41 ]

    [ -e "$p/share/applications/1cv8c.desktop" ]
    touch "$out"
  '';

  training = runCommand "onec-test-training" { } ''
    set -eu
    p=${onecTraining}
    o=${onecTraining.dist}/opt/1cv8t
    [ "${onecTraining.version}" = "${trainingVersion}" ]
    [ "${onecTraining.optName}" = 1cv8t ]
    [ "${toString onecTraining.profiles}" = client ]
    grep -qx 'client_full,ru' "$o/x86_64/${trainingVersion}/installed-components"
    grep -qx 'v8_install_deps,desktop_icons,ws,en' "$o/x86_64/${trainingVersion}/disabled-components"
    [ -x "$o/common/1cestartt" ]
    for b in 1cv8t 1cv8ct 1cestartt; do
      [ -x "$p/bin/$b" ] || { echo "нет обёртки $b" >&2; exit 1; }
    done
    [ -e "$p/share/applications/1cestartt.desktop" ]
    [ "$(cat "$o/x86_64/${trainingVersion}/webkit2ext/webkit2_extu-3.0.so")" = ext41 ]
    touch "$out"
  '';

  # Компонента нет в дистрибутиве — понятная ошибка ещё до установки.
  missing-component =
    let
      failed = pkgs.testers.testBuildFailure onecTrainingServer.dist;
    in
    runCommand "onec-test-missing-component" { } ''
      grep -q 'нет компонентов: server' ${failed}/testBuildFailure.log
      grep -q 'доступны: client_full' ${failed}/testBuildFailure.log
      touch "$out"
    '';

  legacy-deb = runCommand "onec-test-legacy-deb" { } ''
    set -eu
    [ "${onecLegacy.version}" = 8.3.12.1855 ]
    [ -x ${onecLegacy.dist}/opt/1cv8/x86_64/8.3.12.1855/1cv8c ]
    [ -x ${onecLegacy}/bin/1cv8c ]
    [ -f ${onecLegacy.dist}/opt/1cv8/conf/conf.cfg ]
    touch "$out"
  '';

  # Серверному окружению не нужен графический стек.
  server-profile = runCommand "onec-test-server-profile" { } ''
    set -eu
    [ "${toString onecServerOnly.profiles}" = server ]
    if grep -E -- '-(webkitgtk|gtk\+3|gstreamer)-' ${closure onecServerOnly.fhs}/store-paths; then
      echo "серверное FHS-окружение тянет GUI-библиотеки" >&2; exit 1
    fi
    grep -q -- '-cups-.*-lib$' ${closure onecTraining.fhs}/store-paths
    touch "$out"
  '';

  module-eval =
    let
      rules = mcfg.systemd.tmpfiles.rules;
      trules = tcfg.systemd.tmpfiles.rules;
    in
    assert lib.elem "d /var/1C/licenses 2775 root grp1cv8 -" rules;
    assert lib.elem "grp1cv8" mcfg.users.users.alice.extraGroups;
    assert mcfg.users.groups ? grp1cv8;
    assert lib.any (lib.hasPrefix "C /opt/1cv8/conf/conf.cfg ") rules;
    assert lib.any (lib.hasPrefix "L+ /opt/1cv8t/x86_64/${trainingVersion} ") trules;
    assert failedAssertions tcfg == [ ];
    assert failedAssertions mcfg == [ ];
    assert lib.length (failedAssertions tcfgServer) == 1;
    pkgs.writeText "onec-test-module" ''
      ragent: ${mcfg.systemd.services."1c-ragent".serviceConfig.ExecStart}
      ras: ${mcfg.systemd.services."1c-ras".serviceConfig.ExecStart}
      tmpfiles: ${lib.concatStringsSep "\n" rules}
      ports: ${toString mcfg.networking.firewall.allowedTCPPorts}
      pkgs: ${toString (map (p: p.name) mcfg.environment.systemPackages)}
      training: ${lib.concatStringsSep "\n" trules}
    '';

  # Обёртка реально заходит в FHS-окружение. Нужны user namespaces внутри
  # песочницы сборки — на NixOS они есть, в некоторых CI нет.
  fhs-run = runCommand "onec-test-fhs-run" { } ''
    set -eu
    out1="$(${onecFromInstaller}/bin/1cv8c /F /tmp/base 2>&1)"
    echo "$out1"
    echo "$out1" | grep -q 'fake 1cv8c /F /tmp/base'
    echo "$out1" | grep -q fhs-ok
    # обходы X11 (x11-fixes.c) подгружаются клиентам и не мешают процессу
    echo "$out1" | grep -qx 'preload=${onecFromInstaller.x11Fixes}/lib/libonec-x11-fixes.so'

    out2="$(${onecTraining}/bin/1cestartt 2>&1)"
    echo "$out2" | grep -q 'fake 1cestartt'
    echo "$out2" | grep -q 'preload=.*libonec-x11-fixes.so'

    # серверу — нет
    out3="$(${onecServerOnly}/bin/ragent 2>&1)"
    echo "$out3" | grep -qx 'preload='

    loc="$(${onecTraining}/bin/onec-shell -c 'LC_ALL=ru_RU.UTF-8 date -d @0 +%B' 2>&1)"
    echo "$loc"
    [ "$loc" = января ] || [ "$loc" = январь ]

    # масштаб из параметра и его переопределение на один запуск
    s1="$(${onecTraining}/bin/onec-shell -c 'echo $GDK_DPI_SCALE' 2>/dev/null)"
    s2="$(ONEC_SCALE=1.5 ${onecTraining}/bin/onec-shell -c 'echo $GDK_DPI_SCALE' 2>/dev/null)"
    echo "scale: $s1 / $s2"
    [ "$s1" = 1.250000 ] && [ "$s2" = 1.5 ]
    touch "$out"
  '';
}
