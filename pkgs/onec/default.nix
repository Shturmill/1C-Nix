# Стадия 2: запуск платформы 1С в FHS-окружении.
#
# Бинарники 1С не патчатся (autoPatchelf и подмены dlopen не нужны): они
# запускаются в FHS-окружении buildFHSEnv (bubblewrap), где /usr/lib содержит
# библиотеки из nixpkgs, а собственные .so платформы находятся через $ORIGIN.
# Это не изоляция: окружению видны /home, /run, /dev, сеть и D-Bus.
#
# Использование:
#   pkgs.callPackage ./pkgs/onec { src = <дистрибутив>; }
{
  lib,
  callPackage,
  buildFHSEnv,
  writeShellScript,
  runCommand,
  runCommandCC,
  runtimeShell,
  makeDesktopItem,
  makeFontsConf,
  writeText,
  pkgs,

  # Дистрибутив: store-путь или деривация (обычно pkgs.requireFile).
  src,
  # Версия платформы. По умолчанию берётся из имени файла
  # (server64_8_3_27_2130.tar.gz -> 8.3.27.2130).
  version ? null,
  # Каталог в /opt: «1cv8» или «1cv8t» (учебная версия). По умолчанию —
  # «1cv8t», если в имени файла есть «training».
  optName ? null,
  # Компоненты инсталлятора (--enable-components). Язык (language)
  # добавляется сам. Тонкий клиент входит в client_full. Для старых
  # .deb-архивов игнорируется — распаковывается всё, что лежит в архиве.
  components ? [ "client_full" ],
  disabledComponents ? [ ],
  # Отключить все компоненты дистрибутива, кроме перечисленных в components
  # (иначе инсталлятор добавит свой набор по умолчанию: ws, en…).
  autoDisableComponents ? true,
  language ? "ru",
  # Наборы библиотек FHS-окружения (см. runtime-deps.nix): подмножество
  # [ "client" "server" ]; common входит всегда. null — по components.
  runtimeProfiles ? null,
  # Переключать WebKit-зависимые библиотеки 1С на сборку под webkitgtk 4.1.
  preferWebkit41 ? true,
  # Имена бандловых .so, которые нужно удалить, чтобы брались из nixpkgs
  # (ручка для отладки падений, например [ "libcairo-v8.so" ]).
  dropBundledLibs ? [ ],
  # Дополнительные пакеты в FHS-окружение (функция pkgs -> [ ... ]).
  extraPkgs ? (_: [ ]),
  # Масштаб интерфейса клиентов 1С, дробный (1.25 = 125 %). null — как в
  # системе. На один запуск: ONEC_SCALE=1.5 1cv8c.
  scale ? null,
  # Подгружать клиентам обходы дефектов окон X11 (x11-fixes.c). На один
  # запуск отключаются без пересборки: ONEC_NO_X11_FIXES=1 1cv8.
  enableX11Fixes ? true,
  # Обход долгого закрытия окон из x11-fixes.c (эвристика по времени,
  # поэтому выключен). На один запуск: ONEC_X11_FAST_CLOSE=1 1cv8.
  x11FastClose ? false,
}:

let
  # Имя файла дистрибутива без хеша store-пути.
  srcName =
    let
      raw = src.name or (baseNameOf (toString src));
      m = builtins.match "[0-9a-z]{32}-(.*)" raw;
    in
    if m == null then raw else builtins.head m;

  parsedVersion =
    let
      m = builtins.match ".*(8)_([0-9]+)_([0-9]+)_([0-9]+).*" srcName;
      m2 = builtins.match ".*(8)\\.([0-9]+)\\.([0-9]+)[.-]([0-9]+).*" srcName;
      hit = if m != null then m else m2;
    in
    if hit == null then null else lib.concatStringsSep "." hit;

  finalVersion =
    if version != null then
      version
    else if parsedVersion != null then
      parsedVersion
    else
      throw "onec: не удалось определить версию из имени «${srcName}», задайте version явно";

  # training_8_3_27_1508_LinuxRun.tar.gz, setup-training-*.run
  finalOptName =
    if optName != null then
      optName
    else if lib.hasInfix "training" (lib.toLower srcName) then
      "1cv8t"
    else
      "1cv8";

  isTraining = finalOptName == "1cv8t";

  # 1.25 -> "1.250000": GDK разбирает его как обычное число.
  scaleStr = if scale == null then "" else toString scale;

  finalComponents = lib.unique (components ++ [ language ]);

  # Локаль по умолчанию (LANG), если своей нет: по языку интерфейса.
  defaultLocale =
    {
      ru = "ru_RU.UTF-8";
      en = "en_US.UTF-8";
      uk = "uk_UA.UTF-8";
      be = "be_BY.UTF-8";
      kk = "kk_KZ.UTF-8";
      de = "de_DE.UTF-8";
    }
    .${language} or "C.UTF-8";

  dist = callPackage ./dist.nix {
    inherit
      src
      disabledComponents
      autoDisableComponents
      language
      preferWebkit41
      dropBundledLibs
      ;
    version = finalVersion;
    optName = finalOptName;
    components = finalComponents;
  };

  # Профили библиотек: клиенту — GTK/WebKit, серверу — только то, что нужно
  # без дисплея. Так серверное замыкание не тянет webkitgtk и gstreamer.
  wantClient = lib.any (lib.hasPrefix "client") components;
  wantServer = lib.any (
    c:
    lib.elem c [
      "server"
      "server_admin"
      "ws"
      "ibcmd"
      "config_storage_server"
    ]
  ) components;
  profiles =
    if runtimeProfiles != null then
      runtimeProfiles
    else if !wantClient && !wantServer then
      [
        "client"
        "server"
      ]
    else
      lib.optional wantClient "client" ++ lib.optional wantServer "server";

  runtimeDeps =
    pkgs:
    let
      sets = import ./runtime-deps.nix pkgs;
    in
    lib.unique (sets.common ++ lib.concatMap (p: sets.${p}) profiles);

  # Обходы дефектов окон 1С под X11 (серые полосы после fullscreen, долгое
  # закрытие) — см. x11-fixes.c. Своих зависимостей нет: функции Xlib
  # берутся из уже загруженной процессом libX11.
  x11Fixes =
    runCommandCC "onec-x11-fixes"
      {
        buildInputs = [ (pkgs.libx11 or pkgs.xorg.libX11) ];
      }
      ''
        mkdir -p "$out/lib"
        cc -O2 -Wall -shared -fPIC \
          -o "$out/lib/libonec-x11-fixes.so" ${./x11-fixes.c} -ldl -lpthread
      '';

  # Точка входа FHS-окружения: первым аргументом — имя бинарника платформы.
  # Без аргументов открывает bash внутри окружения (удобно для ldd/отладки),
  # с «-c …» выполняет команду в нём.
  dispatcher = writeShellScript "onec-dispatch" ''
    if [ "$#" -eq 0 ]; then exec bash; fi
    if [ "$1" = "-c" ]; then exec bash "$@"; fi
    prog="$1"; shift
    ${lib.optionalString enableX11Fixes ''
      case "$prog" in
        1cv8 | 1cv8c | 1cestart | 1cv8t | 1cv8ct | 1cestartt)
          if [ "''${ONEC_NO_X11_FIXES:-}" != 1 ]; then
            export LD_PRELOAD="${x11Fixes}/lib/libonec-x11-fixes.so''${LD_PRELOAD:+ $LD_PRELOAD}"
            ${lib.optionalString x11FastClose ''export ONEC_X11_FAST_CLOSE="''${ONEC_X11_FAST_CLOSE:-1}"''}
          fi
          ;;
      esac
    ''}
    for d in ${dist}/opt/1cv8*/x86_64/*/ ${dist}/opt/1cv8*/common/; do
      if [ -x "$d$prog" ] && [ -f "$d$prog" ]; then exec "$d$prog" "$@"; fi
    done
    echo "onec: в установленной платформе нет «$prog»" >&2
    exit 127
  '';

  # Шрифты. Конфигурация NixOS не видит /usr/share/fonts окружения (там
  # corefonts для печатных форм), а без /etc/fonts (не-NixOS, песочница
  # сборки) GTK остаётся вовсе без шрифтов и клиент 1С зависает на старте.
  fontsConfHost = writeText "onec-fonts.conf" ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
    <fontconfig>
      <include ignore_missing="yes">/etc/fonts/fonts.conf</include>
      <dir>/usr/share/fonts</dir>
    </fontconfig>
  '';
  fontsConfStandalone = makeFontsConf { fontDirectories = [ ]; };

  fhs = buildFHSEnv {
    pname = "onec-fhs";
    version = finalVersion;
    targetPkgs = pkgs: runtimeDeps pkgs ++ extraPkgs pkgs;
    runScript = dispatcher;
    profile = ''
      # Архив локалей окружения, а не хоста (там может не быть ru_RU).
      # LOCALE_ARCHIVE_2_27 (NixOS) glibc читает раньше LOCALE_ARCHIVE.
      export LOCALE_ARCHIVE=/usr/lib/locale/locale-archive
      unset LOCALE_ARCHIVE_2_27
      # LANG/LC_* пользователя (и сервиса) не трогаем.
      export LANG="''${LANG:-${defaultLocale}}"

      # 1С поддерживает только X11; под Wayland-композитором работаем через
      # XWayland. Своё значение: ONEC_GDK_BACKEND=wayland.
      export GDK_BACKEND="''${ONEC_GDK_BACKEND:-x11}"

      # Дробный масштаб. Под X11 GDK_SCALE бывает только целым, а Xft.dpi
      # 1С игнорирует; GDK_DPI_SCALE 1С учитывает целиком — шрифты, высоту
      # строк и панелей, иконки (проверено на 1cv8t и 1cv8ct 8.3.27).
      # Под Wayland с xwayland:force_zero_scaling XWayland-окна не
      # масштабируются композитором — это и есть способ задать им масштаб.
      onec_scale="''${ONEC_SCALE:-${scaleStr}}"
      [ -z "$onec_scale" ] || export GDK_DPI_SCALE="$onec_scale"
      unset onec_scale

      if [ -z "''${FONTCONFIG_FILE:-}" ]; then
        if [ -e /etc/fonts/fonts.conf ]; then
          export FONTCONFIG_FILE=${fontsConfHost}
        else
          export FONTCONFIG_FILE=${fontsConfStandalone}
        fi
      fi
    '';
  };

  # Все исполняемые файлы, которые могут встретиться в поставке.
  # Суффикс «t» — учебная версия (/opt/1cv8t).
  knownPrograms = [
    "1cestart"
    "1cv8"
    "1cv8c"
    "1cv8s"
    "ibcmd"
    "ibsrv"
    "ragent"
    "rmngr"
    "rphost"
    "rac"
    "ras"
    "crserver"
    "webinst"
    "dbgs"
    "chdbfl"
    "1cestartt"
    "1cv8t"
    "1cv8ct"
    "1cv8st"
    "webinstt"
    "dbgst"
    "chdbflt"
  ];

  t = lib.optionalString isTraining "t";
  edition = lib.optionalString isTraining " (учебная версия)";

  desktopItems = [
    (makeDesktopItem {
      name = "1cestart${t}";
      desktopName = "1С:Предприятие${edition}";
      exec = "1cestart${t} %u";
      icon = "1cestart";
      categories = [
        "Office"
        "Finance"
      ];
    })
    (makeDesktopItem {
      name = "1cv8c${t}";
      desktopName = "1С:Предприятие${edition} — тонкий клиент";
      exec = "1cv8c${t} %u";
      icon = "1cv8c";
      categories = [
        "Office"
        "Finance"
      ];
    })
    (makeDesktopItem {
      name = "1cv8${t}";
      desktopName = "1С:Предприятие${edition} — Конфигуратор";
      exec = "1cv8${t} DESIGNER";
      icon = "1cv8";
      categories = [
        "Office"
        "Development"
      ];
    })
  ];
in
runCommand "onec-platform-${finalVersion}"
  {
    passthru = {
      inherit
        dist
        fhs
        profiles
        x11Fixes
        ;
      version = finalVersion;
      optName = finalOptName;
      # Корень для симлинка /opt/1cv8{,t}/x86_64/<версия> (см. модуль).
      optRoot = "${dist}/opt";
    };
    meta = {
      description = "1С:Предприятие ${finalVersion}${edition} в FHS-окружении (дистрибутив приносит пользователь)";
      license = lib.licenses.unfree;
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
      platforms = [ "x86_64-linux" ];
      hydraPlatforms = [ ];
      mainProgram = "1cestart${t}";
    };
  }
  ''
    mkdir -p "$out/bin" "$out/share/applications"
    for prog in ${lib.concatStringsSep " " knownPrograms}; do
      for d in ${dist}/opt/1cv8*/x86_64/*/ ${dist}/opt/1cv8*/common/; do
        if [ -x "$d$prog" ] && [ -f "$d$prog" ]; then
          printf '#!%s\nexec %s %s "$@"\n' "${runtimeShell}" "${fhs}/bin/onec-fhs" "$prog" > "$out/bin/$prog"
          chmod +x "$out/bin/$prog"
          break
        fi
      done
    done
    ln -s ${fhs}/bin/onec-fhs "$out/bin/onec-shell"

    for item in ${lib.concatMapStringsSep " " (d: "${d}/share/applications/*.desktop") desktopItems}; do
      prog="$(basename "$item" .desktop)"
      [ -e "$out/bin/$prog" ] && cp "$item" "$out/share/applications/"
    done

    # Иконки из поставки под именами из .desktop (1cestart, 1cv8c, 1cv8),
    # если инсталлятор их положил: самая большая подходящая.
    for icon in 1cestart 1cv8c 1cv8; do
      png="$(find ${dist}/opt -name "$icon.png" -printf '%s %p\n' 2>/dev/null \
        | sort -n | tail -n1 | cut -d' ' -f2-)"
      [ -n "$png" ] || continue
      mkdir -p "$out/share/pixmaps"
      cp "$png" "$out/share/pixmaps/$icon.png"
    done
  ''
