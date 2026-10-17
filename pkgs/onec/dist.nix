# Стадия 1: распаковка официального дистрибутива 1С в дерево /opt/1cv8.
#
# Ничего не патчит и не скачивает. На входе — архив, который пользователь
# скачал сам (tar.gz / zip / голый setup-*.run / старый архив с .deb),
# на выходе — $out/opt/1cv8{,t}/... в том же виде, в каком его раскладывает
# штатный инсталлятор. Запуск этого дерева — забота стадии 2 (default.nix).
{
  lib,
  stdenvNoCC,
  bubblewrap,
  dpkg,
  unzip,
  gnutar,
  gzip,
  findutils,
  coreutils,
  gnused,
  gnugrep,
  gawk,
  which,
  bash,
  glibc,

  src,
  version,
  optName,
  components,
  disabledComponents,
  autoDisableComponents,
  language,
  preferWebkit41,
  dropBundledLibs,
}:

let
  # Что вызывают инсталлятор и его postinst-скрипты (ln -frs, sed -i, awk…).
  installerPath = lib.makeBinPath [
    coreutils
    findutils
    gnused
    gnugrep
    gawk
    which
  ];
in
# Имена файлов, а не пути: удаляются внутри каталога платформы.
assert lib.assertMsg (lib.all (
  n: builtins.match "[A-Za-z0-9._+-]+" n != null
) dropBundledLibs) "onec: dropBundledLibs — только имена файлов (libfoo.so), без путей";
stdenvNoCC.mkDerivation {
  pname = "onec-dist";
  inherit version src;

  nativeBuildInputs = [
    bubblewrap
    dpkg
    unzip
    gnutar
    gzip
    findutils
    gnugrep
    gawk
  ];

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  dontFixup = true; # бинарники не трогаем: их запускает FHS-окружение

  # Передаём списки в скрипт через окружение, а не интерполяцией в bash.
  onecOptName = optName;
  onecComponents = lib.concatStringsSep "," components;
  onecDisabled = lib.concatStringsSep "," disabledComponents;
  onecAutoDisable = if autoDisableComponents then "1" else "";
  onecLanguage = language;
  onecPreferWebkit41 = if preferWebkit41 then "1" else "";
  onecDrop = lib.concatStringsSep " " dropBundledLibs;

  installPhase = ''
    runHook preInstall

    work="$NIX_BUILD_TOP/work"
    root="$NIX_BUILD_TOP/root"
    mkdir -p "$work" "$root" "$NIX_BUILD_TOP/tmp"

    # --- 1. Достаём содержимое архива ------------------------------------
    srcName="$(stripHash "$src")"
    case "$srcName" in
      *.run)            cp "$src" "$work/$srcName" ;;
      *.zip)            unzip -q "$src" -d "$work" ;;
      *.tar.gz|*.tgz)   tar -xzf "$src" -C "$work" ;;
      *.tar)            tar -xf "$src" -C "$work" ;;
      *)
        echo "onec: неизвестный формат дистрибутива: $srcName" >&2
        echo "      ожидается .tar.gz, .zip или setup-*.run" >&2
        exit 1 ;;
    esac

    installer="$(find "$work" -type f -name 'setup-*.run' | sort | head -n1)"
    [ -n "$installer" ] || installer="$(find "$work" -type f -name '*.run' | sort | head -n1)"

    if [ -n "$installer" ]; then
      # --- 2a. Новый формат (8.3.18+): единый инсталлятор ----------------
      # Это обычный Linux-бинарник (InstallBuilder), которому нужны root,
      # системный загрузчик /lib64/ld-linux-x86-64.so.2, /bin/bash для
      # postinst-скриптов и ln/sed/awk в PATH. Даём всё это в отдельном
      # пространстве имён bubblewrap — на хост это не влияет.
      #
      # Ставим по штатным путям: каталог сборки монтируется как /opt.
      # --prefix не используем: в --help его нет, а postinst-скрипты всё
      # равно работают с зашитым /opt/1cv8{,t} — с --prefix они не находят
      # файлы, и 1cestart не переносится в common/.
      echo "onec: найден инсталлятор $(basename "$installer")"
      chmod +x "$installer"
      mkdir -p "$root/opt" "$root/applications"

      # /etc хоста не пробрасываем: postinst ветвится по /etc/os-release,
      # а результат сборки не должен зависеть от машины. Сеть, PID и IPC
      # тоже отдельные: не полагаемся только на песочницу Nix (при
      # sandbox = false проприетарный инсталлятор иначе получил бы сеть).
      sandbox=(bwrap
        --unshare-all --unshare-user --uid 0 --gid 0
        --die-with-parent --new-session
        --ro-bind /nix /nix
        --ro-bind-try /etc/passwd /etc/passwd
        --ro-bind-try /etc/group /etc/group
        --proc /proc --dev /dev
        --tmpfs /tmp --tmpfs /var
        --bind "$NIX_BUILD_TOP" "$NIX_BUILD_TOP"
        --bind "$root/opt" /opt
        --bind "$root/applications" /usr/share/applications
        --symlink ${glibc}/lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2
        --symlink ${bash}/bin/bash /bin/bash
        --symlink ${bash}/bin/bash /bin/sh
        --symlink ${bash}/bin/bash /usr/bin/bash
        --symlink ${coreutils}/bin/env /usr/bin/env
        --unsetenv USER
        --setenv PATH "${installerPath}"
        --setenv TMPDIR "$NIX_BUILD_TOP/tmp"
        --setenv HOME "$NIX_BUILD_TOP/tmp"
        --chdir "$work"
        --)

      # Какие компоненты есть в этом дистрибутиве: последняя строка блока
      # --enable-components в выводе --help («Разрешено: …» / «Allowed: …»).
      allowed="$("''${sandbox[@]}" "$installer" --help 2>&1 \
        | awk '/^ *--enable-components/ { f = 1; next }
               f && /^ *$/ { exit }
               f { l = $0 }
               END { sub(/.*: */, "", l); print l }' || true)"

      enable="$onecComponents"
      disable="$onecDisabled"
      if [ -n "$allowed" ]; then
        echo "onec: компоненты дистрибутива: $allowed"
        bad=""
        for c in ''${enable//,/ } ''${disable//,/ }; do
          case " $allowed " in *" $c "*) ;; *) bad="$bad $c" ;; esac
        done
        if [ -n "$bad" ]; then
          echo "onec: в дистрибутиве $(basename "$installer") нет компонентов:$bad" >&2
          echo "      доступны: $allowed" >&2
          echo "      (в учебной версии нет server/server_admin/client_thin —" >&2
          echo "      тонкий клиент входит в client_full)" >&2
          exit 1
        fi
        # Всё, что не попросили, явно отключаем: иначе инсталлятор добавит
        # свой набор по умолчанию (ws, en…), и состав пакета будет зависеть
        # от того, что 1С решила включить в этой версии.
        if [ -n "$onecAutoDisable" ]; then
          for c in $allowed; do
            case ",$enable,$disable," in
              *",$c,"*) ;;
              *) disable="''${disable:+$disable,}$c" ;;
            esac
          done
        fi
      elif [ -n "$onecAutoDisable" ]; then
        # Без списка не отключить лишнее: состав пакета зависел бы от
        # набора 1С по умолчанию (см. выше).
        echo "onec: не удалось прочитать список компонентов из --help $(basename "$installer")" >&2
        echo "      (сборка с autoDisableComponents = false пропустит проверку)" >&2
        exit 1
      else
        echo "onec: не удалось прочитать список компонентов из --help, проверка пропущена" >&2
      fi

      args=(--mode unattended --unattendedmodeui none
            --installer-language "$onecLanguage")
      [ -z "$enable" ]  || args+=(--enable-components "$enable")
      [ -z "$disable" ] || args+=(--disable-components "$disable")
      echo "onec: запуск: $(basename "$installer") ''${args[*]}"

      rc=0
      "''${sandbox[@]}" "$installer" "''${args[@]}" || rc=$?
      if [ "$rc" -ne 0 ]; then
        echo "onec: инсталлятор завершился с кодом $rc" >&2
        exit 1
      fi
    else
      # --- 2b. Старый формат: архив с .deb-пакетами ----------------------
      mapfile -t debs < <(find "$work" -type f -name '*.deb' | sort)
      if [ "''${#debs[@]}" -eq 0 ]; then
        echo "onec: в архиве нет ни инсталлятора *.run, ни пакетов *.deb:" >&2
        find "$work" -maxdepth 3 >&2
        exit 1
      fi
      for d in "''${debs[@]}"; do
        echo "onec: распаковка $(basename "$d")"
        dpkg-deb -x "$d" "$root"
      done
    fi

    # --- 3. Приводим раскладку к /opt/1cv8{,t}/x86_64/<версия> -------------
    mkdir -p "$out/opt"
    found=""
    for top in 1cv8 1cv8t; do
      if [ -d "$root/opt/$top" ]; then
        cp -a "$root/opt/$top" "$out/opt/$top"
        found=1
      fi
    done
    if [ -z "$found" ] && [ -d "$root/opt/1C/v8.3/x86_64" ]; then
      # Раскладка до 8.3.18: одна версия в /opt/1C/v8.3/x86_64.
      mkdir -p "$out/opt/$onecOptName/x86_64"
      cp -a "$root/opt/1C/v8.3/x86_64" "$out/opt/$onecOptName/x86_64/$version"
      found=1
    fi
    if [ -z "$found" ]; then
      echo "onec: после установки не найден каталог платформы в $root/opt:" >&2
      find "$root" -maxdepth 4 -type d >&2
      exit 1
    fi
    chmod -R u+w "$out/opt"

    if [ ! -d "$out/opt/$onecOptName/x86_64/$version" ]; then
      echo "onec: ожидался каталог /opt/$onecOptName/x86_64/$version, а установлено:" >&2
      find "$out/opt" -mindepth 1 -maxdepth 3 -type d >&2
      echo "      проверьте version (и optName для учебной версии)" >&2
      exit 1
    fi

    # --- 4. Минимальная правка поставки -----------------------------------
    for dir in "$out"/opt/1cv8*/x86_64/* "$out"/opt/1cv8*/common; do
      [ -d "$dir" ] || continue

      # Свои libstdc++/libgcc_s у 1С старее, чем нужно webkitgtk из nixpkgs
      # (ошибка «GLIBCXX_3.4.xx not found»). Без них берутся из окружения.
      rm -f "$dir"/libstdc++.so.6* "$dir/libgcc_s.so.1"

      # В поставке лежат две сборки WebKit-зависимых библиотек: под
      # webkitgtk 4.0 (по умолчанию) и под 4.1 (суффикс .wk41). В nixpkgs
      # осталась только 4.1 — подменяем каждый X на X.wk41. Ссылки вида
      # webkit2ext/webkit2_extu-3.0.so -> ../webkit2_extu-3.0.so при этом
      # продолжают работать.
      if [ -n "$onecPreferWebkit41" ]; then
        for alt in "$dir"/*.wk41; do
          [ -e "$alt" ] || continue
          base="''${alt%.wk41}"
          rm -f "$base"
          ln -s "$(basename "$alt")" "$base"
          echo "onec: $(basename "$base") -> $(basename "$alt")"
        done
      fi

      for lib in $onecDrop; do
        rm -f "$dir/$lib"
      done

      # Служебные файлы инсталлятора с путями песочницы сборки.
      rm -f "$dir"/uninstaller-* "$dir"/uninstallAsRoot "$dir"/*.desktop
    done

    # Общий conf.cfg (его создаёт postinst; в старых .deb его нет).
    for top in "$out"/opt/1cv8*; do
      if [ ! -f "$top/conf/conf.cfg" ]; then
        mkdir -p "$top/conf"
        echo "SystemLanguage=System" > "$top/conf/conf.cfg"
      fi
    done

    # --- 5. Проверка результата -------------------------------------------
    # Ловим «тихие» сбои инсталлятора: компонент заказан, а файлов нет.
    # Для .deb-архивов components не применяются — не проверяем.
    vdir="$out/opt/$onecOptName/x86_64/$version"
    t=""; [ "$onecOptName" = 1cv8t ] && t=t
    missing=""; starter=""
    need() { [ -x "$vdir/$1" ] || [ -x "$out/opt/$onecOptName/common/$1" ] || missing="$missing $1"; }
    checkComponents=""
    [ -z "$installer" ] || checkComponents="''${onecComponents//,/ }"
    for c in $checkComponents; do
      case "$c" in
        client_full)  need "1cv8$t"; need "1cv8c$t"; starter=1 ;;
        client_thin*) need "1cv8c$t"; starter=1 ;;
        server)       need ragent; need rphost; need rmngr ;;
        server_admin) need ras; need rac ;;
      esac
    done
    # 1cestart переносит в common/ postinst-скрипт — если он не отработал,
    # стартер останется в каталоге версии.
    if [ -n "$installer" ] && [ -n "$starter" ] && [ ! -x "$out/opt/$onecOptName/common/1cestart$t" ]; then
      missing="$missing common/1cestart$t"
    fi
    if [ -n "$missing" ]; then
      echo "onec: после установки нет ожидаемых файлов:$missing" >&2
      echo "      установлено в $vdir:" >&2
      ls "$vdir" >&2
      exit 1
    fi

    runHook postInstall
  '';

  meta = {
    description = "Распакованный дистрибутив 1С:Предприятие (без изменений бинарников)";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    hydraPlatforms = [ ];
  };
}
