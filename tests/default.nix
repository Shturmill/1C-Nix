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

  onecNoX11Fixes = self.lib.mkOnec pkgs {
    src = installerTarball;
    enableX11Fixes = false;
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
        range = "1560:1591,1600:1610";
      };
      ras.enable = true;
      licensesDir.users = [ "alice" ];
    }).config;

  # Сервер от своего пользователя (root уже объявлен в NixOS).
  ucfg =
    (mkSystem {
      src = installerTarball;
      keepSrc = false;
      server = {
        enable = true;
        user = "root";
        group = "root";
      };
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

  # RAS для удалённого агента, без локального сервера.
  rcfg =
    (mkSystem {
      src = installerTarball;
      ras = {
        enable = true;
        agentAddress = "192.168.1.100:1540";
      };
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

  # В --help нет списка компонентов: с autoDisableComponents сборка
  # останавливается, без него — ставит, что попросили.
  help-unparsed =
    let
      tarball = mkTarball {
        name = "server64_8_3_99_3.tar.gz";
        runName = "setup-full-8.3.99.3-x86_64.run";
        installer = mkFakeInstaller {
          version = "8.3.99.3";
          allowed = "";
        };
      };
      failed = pkgs.testers.testBuildFailure (self.lib.mkOnec pkgs { src = tarball; }).dist;
      lenient = self.lib.mkOnec pkgs {
        src = tarball;
        autoDisableComponents = false;
      };
    in
    runCommand "onec-test-help-unparsed" { } ''
      grep -q 'не удалось прочитать список компонентов' ${failed}/testBuildFailure.log
      [ -x ${lenient.dist}/opt/1cv8/x86_64/8.3.99.3/1cv8 ]
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
      ragent = mcfg.systemd.services."1c-ragent";
      ras = mcfg.systemd.services."1c-ras";
      rras = rcfg.systemd.services."1c-ras";
    in
    assert lib.elem "d /var/1C/licenses 2775 root grp1cv8lic -" rules;
    assert lib.elem "grp1cv8lic" mcfg.users.users.alice.extraGroups;
    assert !(lib.elem "grp1cv8" mcfg.users.users.alice.extraGroups);
    assert lib.elem "grp1cv8lic" mcfg.users.users.usr1cv8.extraGroups;
    assert mcfg.users.groups ? grp1cv8 && mcfg.users.groups ? grp1cv8lic;
    assert lib.any (lib.hasPrefix "C /opt/1cv8/conf/conf.cfg ") rules;
    assert lib.elem "L+ /opt/1cv8t/x86_64 - - - - ${onecTraining.optRoot}/1cv8t/x86_64" trules;
    assert !(lib.any (lib.hasPrefix "d /opt/1cv8t/x86_64") trules);
    assert failedAssertions tcfg == [ ];
    assert failedAssertions mcfg == [ ];
    assert lib.length (failedAssertions tcfgServer) == 1;
    # открытый файрвол при seclev 0 — предупреждение, без него — нет
    assert lib.length (lib.filter (lib.hasPrefix "services.onec:") mcfg.warnings) == 1;
    assert lib.filter (lib.hasPrefix "services.onec:") tcfg.warnings == [ ];
    assert lib.length mcfg.networking.firewall.allowedTCPPortRanges == 2;
    assert lib.elem "${installerTarball}" mcfg.system.extraDependencies;
    assert ucfg.system.extraDependencies == [ ];
    assert ragent.serviceConfig.NoNewPrivileges && ragent.serviceConfig.ProtectSystem == "strict";
    assert ucfg.users.users.root.home == "/root";
    # тип description: без двоеточий и переводов строки
    assert mcfg.users.users.usr1cv8.description != "";
    assert !(ucfg.users.users ? usr1cv8);
    assert lib.hasInfix "-seclev 0 " ragent.serviceConfig.ExecStart;
    assert lib.hasInfix "-pingPeriod 1000 -pingTimeout 5000" ragent.serviceConfig.ExecStart;
    assert lib.hasSuffix " localhost:1540" ras.serviceConfig.ExecStart;
    assert lib.elem "1c-ragent.service" ras.requires;
    assert lib.hasSuffix " 192.168.1.100:1540" rras.serviceConfig.ExecStart;
    assert rras.requires == [ ];
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

    # отключение на один запуск и параметром пакета
    out_off="$(ONEC_NO_X11_FIXES=1 ${onecFromInstaller}/bin/1cv8c 2>&1)"
    echo "$out_off" | grep -qx 'preload='
    out_off2="$(${onecNoX11Fixes}/bin/1cv8c 2>&1)"
    echo "$out_off2" | grep -qx 'preload='

    out2="$(${onecTraining}/bin/1cestartt 2>&1)"
    echo "$out2" | grep -q 'fake 1cestartt'
    echo "$out2" | grep -q 'preload=.*libonec-x11-fixes.so'

    # серверу — нет
    out3="$(${onecServerOnly}/bin/ragent 2>&1)"
    echo "$out3" | grep -qx 'preload='

    loc="$(${onecTraining}/bin/onec-shell -c 'LC_ALL=ru_RU.UTF-8 date -d @0 +%B' 2>&1)"
    echo "$loc"
    [ "$loc" = января ] || [ "$loc" = январь ]

    # LANG — по языку, только если своего нет; LC_ALL не навязывается
    l1="$(env -u LANG -u LC_ALL ${onecTraining}/bin/onec-shell -c 'echo "$LANG/''${LC_ALL:-}"' 2>/dev/null)"
    l2="$(env -u LC_ALL LANG=en_US.UTF-8 ${onecTraining}/bin/onec-shell -c 'echo "$LANG/''${LC_ALL:-}"' 2>/dev/null)"
    echo "locale: $l1 / $l2"
    [ "$l1" = ru_RU.UTF-8/ ] && [ "$l2" = en_US.UTF-8/ ]

    # масштаб из параметра и его переопределение на один запуск
    s1="$(${onecTraining}/bin/onec-shell -c 'echo $GDK_DPI_SCALE' 2>/dev/null)"
    s2="$(ONEC_SCALE=1.5 ${onecTraining}/bin/onec-shell -c 'echo $GDK_DPI_SCALE' 2>/dev/null)"
    echo "scale: $s1 / $s2"
    [ "$s1" = 1.250000 ] && [ "$s2" = 1.5 ]
    touch "$out"
  '';

  # Обход «пустого окна рядом с диалогом» (x11-fixes.c) на Xvfb, без 1С:
  # override-redirect получает только невидимый родитель 1×1, только в
  # процессах 1С и только пока обходы не отключены. Библиотека не роняет
  # процесс, который подгружает libX11 через dlopen.
  x11-fixes =
    let
      # Сама библиотека собирается без -Werror (у пользователя может быть
      # новее GCC), здесь — строго.
      strict =
        pkgs.runCommandCC "onec-x11-fixes-strict"
          {
            buildInputs = [
              (pkgs.libx11 or pkgs.xorg.libX11)
              (pkgs.libxcb or pkgs.xorg.libxcb)
            ];
          }
          ''
            cc -O2 -Wall -Wextra -Werror -shared -fPIC -fvisibility=hidden \
              -o "$out" ${../pkgs/onec/x11-fixes.c}
          '';
      probe =
        pkgs.runCommandCC "onec-x11-fixes-test"
          {
            buildInputs = [
              (pkgs.libx11 or pkgs.xorg.libX11)
              (pkgs.libxcb or pkgs.xorg.libxcb)
            ];
          }
          ''
            mkdir -p "$out/bin" "$out/lib"
            cc -O2 -Wall -Wextra -Werror -o "$out/bin/x11-fixes-test" ${./x11-fixes-test.c} -lX11
            cc -O2 -Wall -Wextra -Werror -shared -fPIC -DPROBE_LIBRARY \
              -o "$out/lib/libprobe.so" ${./x11-fixes-test.c} -lX11
            cc -O2 -Wall -Wextra -Werror -o "$out/bin/x11-fixes-dlopen" ${./x11-fixes-dlopen.c} -ldl
            ln -s x11-fixes-test "$out/bin/1cv8c"
            ln -s x11-fixes-dlopen "$out/bin/1cv8"
          '';
      so = "${onecFromInstaller.x11Fixes}/lib/libonec-x11-fixes.so";
      steps = pkgs.writeShellScript "onec-x11-fixes-steps" ''
        set -eu
        # check <ожидаемый вывод> <программа> <аргументы…> -- [переменные…]
        check() {
          expect=$1 prog=$2
          shift 2
          args=""
          while [ "$1" != -- ]; do args="$args $1"; shift; done
          shift
          got="$(env "$@" ${probe}/bin/$prog $args)"
          echo "$prog$args $*: $got"
          [ "$got" = "$expect" ]
        }
        pre=LD_PRELOAD=${so}

        # обход 3
        for call in map raised; do
          check override_redirect=1 1cv8c parent "$call" -- $pre
          check override_redirect=0 1cv8c normal "$call" -- $pre
          check override_redirect=0 1cv8c parent "$call" -- $pre ONEC_NO_X11_FIXES=1
          check override_redirect=1 1cv8c parent "$call" -- $pre ONEC_NO_X11_FIXES=0
          check override_redirect=0 1cv8c parent "$call" --
          # не процесс 1С
          check override_redirect=0 x11-fixes-test parent "$call" -- $pre
          for scope in global local; do
            check override_redirect=1 1cv8 ${probe}/lib/libprobe.so $scope parent "$call" -- $pre
            check override_redirect=0 x11-fixes-dlopen ${probe}/lib/libprobe.so $scope parent "$call" -- $pre
          done
        done

        # обход 1: перемещение со старым размером, затем настоящее событие;
        # прежняя геометрия известна с показа окна
        check "50,60 100x100 50,60 200x150" 1cv8c configure late -- $pre
        check "50,60 200x150" 1cv8c configure late --
        check "50,60 200x150" 1cv8c configure late -- $pre ONEC_NO_X11_FIXES=1
        # WM успел до разбора MapNotify: размер в первой половине — прежний
        check "50,60 100x100 50,60 200x150 70,80 200x150 70,80 300x200" \
          1cv8c configure early -- $pre
        check "50,60 200x150 70,80 300x200" 1cv8c configure early --
        # события старше запомненной при показе геометрии с ней не сравниваются
        check "50,60 200x150 70,80 200x150 70,80 300x200" 1cv8c configure premap -- $pre
        check "50,60 200x150 70,80 300x200" 1cv8c configure premap --

        # обход 2: только с ONEC_X11_FAST_CLOSE=1
        fast="$pre ONEC_X11_FAST_CLOSE=1"
        check "wait=hidden key=shown state=kept" 1cv8c close basic -- $fast
        check "wait=shown key=shown state=kept" 1cv8c close basic -- $pre
        # вопрос перед закрытием, короткое ожидание — окно остаётся
        check "wait=shown key=shown state=kept" 1cv8c close dialog -- $fast
        check "wait=shown key=shown state=kept" 1cv8c close short -- $fast
        # окно спрятало само приложение (до или после нас) — по клавише не
        # возвращается
        check "wait=hidden key=hidden state=lost" 1cv8c close self -- $fast
        check "wait=hidden key=hidden state=lost" 1cv8c close self-late -- $fast
        # приложение само показало спрятанное окно — его _NET_WM_STATE не трогаем
        check "wait=hidden key=shown state=lost" 1cv8c close remap -- $fast

        [ -e ${strict} ]
      '';
    in
    runCommand "onec-test-x11-fixes" { nativeBuildInputs = [ pkgs.xvfb-run ]; } ''
      xvfb-run -a -s "-screen 0 640x480x24" ${steps}
      touch "$out"
    '';

  # Модуль в виртуальной машине: ragent и ras под ограничениями systemd
  # действительно запускаются через bubblewrap; /opt и /var/1C/licenses —
  # такие, как ожидают 1cestart и лицензирование.
  module-vm = pkgs.testers.runNixOSTest {
    name = "onec-module-vm";
    nodes.machine = {
      imports = [ self.nixosModules.default ];
      users.users.alice.isNormalUser = true;
      services.onec = {
        enable = true;
        src = installerTarball;
        server.enable = true;
        ras.enable = true;
        licensesDir.users = [ "alice" ];
      };
    };
    testScript = ''
      def show(unit, prop):
          return machine.succeed(f"systemctl show -P {prop} {unit}").strip()

      machine.wait_for_unit("multi-user.target")
      for unit, line in [
          ("1c-ragent", "fake ragent -d /var/lib/1cv8 -port 1540 "),
          ("1c-ras", "fake ras cluster --port=1545 localhost:1540"),
      ]:
          # фальшивый бинарник печатает строку и выходит с кодом 0; если
          # bwrap не запустился, сервис перезапускается с ошибкой
          machine.wait_until_succeeds(f"journalctl -b -u {unit} -o cat | grep -qF -- '{line}'")
          machine.wait_until_succeeds(f"test \"$(systemctl show -P ActiveState {unit})\" = inactive")
          assert show(unit, "ExecMainStatus") == "0", unit
          assert show(unit, "NoNewPrivileges") == "yes", unit
          assert show(unit, "ProtectSystem") == "strict", unit

      machine.succeed("test \"$(stat -c '%a %U %G' /var/1C/licenses)\" = '2775 root grp1cv8lic'")
      machine.succeed("id -nG usr1cv8 | grep -qw grp1cv8lic")
      machine.succeed("id -nG alice | grep -qw grp1cv8lic")
      machine.fail("id -nG alice | grep -qw grp1cv8")

      machine.succeed("test -L /opt/1cv8/x86_64 && test -x /opt/1cv8/x86_64/${fakeVersion}/ragent")
      # старая раскладка (каталог со ссылками на версии) заменяется ссылкой
      machine.succeed(
          "rm /opt/1cv8/x86_64 && mkdir /opt/1cv8/x86_64"
          " && ln -s /nix/store/old /opt/1cv8/x86_64/8.3.0.1"
          " && systemd-tmpfiles --create --prefix /opt/1cv8"
      )
      machine.succeed("test -L /opt/1cv8/x86_64 && test ! -L /opt/1cv8/x86_64/8.3.0.1")
    '';
  };
}
