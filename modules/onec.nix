{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    mkMerge
    types
    optional
    optionals
    unique
    ;

  cfg = config.services.onec;

  # Компоненты с учётом включённых сервисов: серверу нужен «server»,
  # RAS — «server_admin». Язык пакет добавляет сам.
  effectiveComponents = unique (
    cfg.components
    # клиент без явного выбора — толстый (с Конфигуратором); тонкий
    # клиент входит в client_full
    ++ optional (cfg.client.enable && !(lib.any (lib.hasPrefix "client_") cfg.components)) "client_full"
    ++ optional cfg.server.enable "server"
    ++ optional cfg.ras.enable "server_admin"
  );

  pkg = pkgs.callPackage ../pkgs/onec {
    inherit (cfg)
      src
      version
      language
      optName
      ;
    components = effectiveComponents;
    inherit (cfg)
      disabledComponents
      autoDisableComponents
      preferWebkit41
      dropBundledLibs
      extraPkgs
      ;
    inherit (cfg.client) scale;
    enableX11Fixes = cfg.client.x11Fixes.enable;
    x11FastClose = cfg.client.x11Fixes.fastClose;
  };

  o = pkg.optName;
  licGroup = cfg.licensesDir.group;

  # Одна ссылка на весь каталог версий: отдельные ссылки на версии,
  # исчезнувшие из конфигурации, оставались бы в /opt (и выбирались бы
  # 1cestart после отката). Заменяем только ссылку, пустой каталог или
  # прежнюю раскладку модуля (каталог из одних ссылок в /nix/store);
  # чужую установку не трогаем и останавливаемся с ошибкой.
  optLinkScript = pkgs.writeShellScript "onec-link-opt" ''
    set -eu
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.findutils
      ]
    }
    rc=0
    link() {
      dst=$1 target=$2
      if [ -d "$dst" ] && [ ! -L "$dst" ]; then
        if [ -n "$(find "$dst" -mindepth 1 \( ! -type l -o ! -lname '/nix/store/*' \) -print -quit)" ]; then
          echo "services.onec: $dst — каталог не из этого модуля (вероятно, установка" >&2
          echo "  штатным инсталлятором 1С); оставлен как есть, ссылка не создана." >&2
          echo "  Сохраните и уберите его (mv $dst $dst.bak) или задайте" >&2
          echo "  services.onec.linkToOpt = false." >&2
          rc=1
          return
        fi
        find "$dst" -mindepth 1 -delete
        rmdir "$dst"
      elif [ -e "$dst" ] && [ ! -L "$dst" ]; then
        echo "services.onec: $dst существует и не является ссылкой; оставлен как есть." >&2
        rc=1
        return
      fi
      ln -sfnT "$target" "$dst.onec-new"
      mv -fT "$dst.onec-new" "$dst"
    }
    mkdir -p /opt/${o}
    link /opt/${o}/x86_64 ${pkg.optRoot}/${o}/x86_64
    link /opt/${o}/common ${pkg.optRoot}/${o}/common
    exit "$rc"
  '';

  defaultUser = "usr1cv8";
  defaultGroup = "grp1cv8";

  # «1560:1591,1600:1610» -> [ { from = 1560; to = 1591; } … ]
  portRanges = map (
    r:
    let
      p = lib.splitString ":" r;
    in
    {
      from = lib.toInt (builtins.elemAt p 0);
      to = lib.toInt (builtins.elemAt p 1);
    }
  ) (lib.splitString "," cfg.server.range);

  serverUnitCommon = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = cfg.server.user;
      Group = cfg.server.group;
      Restart = "on-failure";
      RestartSec = 5;
      LimitNOFILE = 65536;

      # Бинарники 1С запускаются через bubblewrap (buildFHSEnv) в user
      # namespace. NoNewPrivileges ему не мешает (bwrap без setuid и сам
      # ставит PR_SET_NO_NEW_PRIVS), а ломают его RestrictNamespaces и всё,
      # что перекрывает /proc (ProtectKernelTunables, ProtectKernelLogs,
      # ProtectProc, ProcSubset): в user namespace ядро разрешает
      # смонтировать proc только при полностью видимом /proc.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ReadWritePaths = [
        cfg.server.dataDir
      ]
      ++ optional cfg.licensesDir.enable "/var/1C/licenses";
      LockPersonality = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
      UMask = "0027";
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
      ];
    };
  };
in
{
  options.services.onec = {
    enable = mkEnableOption "платформу 1С:Предприятие 8.3";

    src = mkOption {
      type = types.either types.package types.path;
      example = lib.literalExpression ''
        pkgs.requireFile {
          name = "server64_8_3_27_2130.tar.gz";
          hash = "sha256-...";
          message = "nix store add --mode flat ~/Downloads/server64_8_3_27_2130.tar.gz";
        }
      '';
      description = ''
        Дистрибутив платформы, скачанный с releases.1c.ru: «Технологическая
        платформа 1С:Предприятия (64-bit) для Linux» (.tar.gz / .zip / .run).
        Удобнее всего — `pkgs.requireFile` или `inputs.onec.lib.requireDist`:
        файл один раз кладётся в стор командой `nix store add --mode flat`.
      '';
    };

    version = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "8.3.27.2130";
      description = "Версия платформы. null — определить по имени файла.";
    };

    components = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "client_full"
        "client_thin"
        "ws"
      ];
      description = ''
        Дополнительные компоненты инсталлятора (--enable-components).
        Нужные для включённых client/server/ras добавляются автоматически.
        Список допустимых: `./setup-full-*.run --help`.
      '';
    };

    disabledComponents = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Компоненты, которые явно не ставить (--disable-components).";
    };

    autoDisableComponents = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Отключить все компоненты дистрибутива, кроме нужных (иначе
        инсталлятор добавит свой набор по умолчанию: ws, en…). Список
        берётся из `--help` инсталлятора; если его не удалось прочитать,
        сборка останавливается. false — ставить, как решит инсталлятор.
      '';
    };

    language = mkOption {
      type = types.str;
      default = "ru";
      description = "Язык интерфейса и инсталлятора.";
    };

    preferWebkit41 = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Переключить WebKit-зависимые библиотеки платформы на сборку под
        webkitgtk 4.1 (в nixpkgs 4.0 больше нет).
      '';
    };

    dropBundledLibs = mkOption {
      type = types.listOf (types.strMatching "[A-Za-z0-9._+-]+");
      default = [ ];
      example = [ "libcairo-v8.so" ];
      description = "Бандловые .so платформы, которые удалить (отладка конфликтов библиотек).";
    };

    extraPkgs = mkOption {
      type = types.functionTo (types.listOf types.package);
      default = _: [ ];
      defaultText = lib.literalExpression "_: [ ]";
      description = "Дополнительные пакеты в FHS-окружение платформы.";
    };

    package = mkOption {
      type = types.package;
      readOnly = true;
      description = "Собранный пакет платформы (только чтение).";
    };

    linkToOpt = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Опубликовать платформу по штатному пути /opt/1cv8/x86_64/<версия>
        (ссылкой в /nix/store, служба onec-opt-link). Нужно 1cestart для
        поиска версий, а также внешним инструментам — 1C:EDT,
        vanessa-runner и т.п. Каталог, оставленный штатным инсталлятором
        1С, не удаляется: служба завершится ошибкой, пока его не уберут.
      '';
    };

    optName = mkOption {
      type = types.nullOr (
        types.enum [
          "1cv8"
          "1cv8t"
        ]
      );
      default = null;
      description = ''
        Каталог платформы в /opt: «1cv8» — обычная поставка,
        «1cv8t» — учебная версия. null — по имени файла дистрибутива
        («training» в имени → «1cv8t»).
      '';
    };

    keepSrc = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Держать дистрибутив (src) в замыкании системы. Без этого
        nix-collect-garbage удаляет архив, и первая же пересборка после
        обновления nixpkgs останавливается на requireFile, пока архив не
        добавлен в стор заново.
      '';
    };

    licensesDir = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Создать /var/1C/licenses для программных лицензий.";
      };
      group = mkOption {
        type = types.str;
        default = "grp1cv8lic";
        description = ''
          Группа-владелец /var/1C/licenses. Активировать и использовать
          программные лицензии могут root и члены этой группы. Отдельная от
          группы сервера: пользователи настольных машин не должны попадать в
          группу серверного процесса. Пользователь сервера добавляется в неё
          сам.
        '';
      };
      mode = mkOption {
        type = types.strMatching "[0-7]{3,4}";
        default = "2775";
        description = ''
          Права на /var/1C/licenses: владелец root, запись — группе, остальным
          только чтение (рекомендация 1С). Бит setgid (2xxx) нужен, чтобы
          файлы лицензий, созданные одним пользователем, принадлежали группе
          и были доступны остальным её членам.
        '';
      };
      users = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "alice" ];
        description = ''
          Пользователи, которых добавить в группу licensesDir.group (нужно
          для активации лицензии из клиента). Пользователь сервера 1С
          входит в неё и так.
        '';
      };
    };

    client = {
      enable = mkEnableOption "клиент 1С (1cestart, 1cv8c, 1cv8) в системном PATH";
      fonts = mkOption {
        type = types.bool;
        default = true;
        description = "Установить corefonts (Arial, Times New Roman…), под которые свёрстаны печатные формы.";
      };
      scale = mkOption {
        type = types.nullOr types.numbers.positive;
        default = null;
        example = 1.25;
        description = ''
          Масштаб интерфейса клиентов 1С, произвольный дробный: 1.25 = 125 %.
          null — без изменений. Переопределить на один запуск:
          `ONEC_SCALE=1.5 1cv8c`. Работает через GDK_DPI_SCALE, поэтому
          одинаков на всех мониторах.
        '';
      };
      x11Fixes.enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Подгружать клиентам LD_PRELOAD-библиотеку с обходами дефектов окон
          1С под X11/XWayland (pkgs/onec/x11-fixes.c): серые полосы после
          fullscreen/тайлинга и пустое окно рядом с диалогом. На один запуск
          отключается без пересборки: `ONEC_NO_X11_FIXES=1 1cv8`.
        '';
      };
      x11Fixes.fastClose = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Прятать закрываемое окно, не дожидаясь, пока 1С остановит свои
          потоки (~2 с). Держится на эвристике по времени (перехват
          sem_wait, pthread_join, nanosleep), поэтому выключено. На один
          запуск: `ONEC_X11_FAST_CLOSE=1 1cv8`.
        '';
      };
    };

    server = {
      enable = mkEnableOption "кластер серверов 1С (ragent)";
      user = mkOption {
        type = types.str;
        default = defaultUser;
        description = ''
          Пользователь сервера 1С. Создаётся модулем, только если оставлен
          по умолчанию; своего пользователя объявите сами.
        '';
      };
      group = mkOption {
        type = types.str;
        default = defaultGroup;
        description = ''
          Группа сервера 1С. Создаётся модулем, только если оставлена по
          умолчанию.
        '';
      };
      dataDir = mkOption {
        type = types.strMatching "/.+";
        default = "/var/lib/1cv8";
        description = "Каталог данных кластера (параметр -d).";
      };
      port = mkOption {
        type = types.port;
        default = 1540;
        description = "Порт агента сервера (ragent).";
      };
      regport = mkOption {
        type = types.port;
        default = 1541;
        description = "Порт главного менеджера кластера.";
      };
      securityLevel = mkOption {
        type = types.enum [
          0
          1
          2
        ];
        default = 0;
        description = ''
          Уровень безопасности соединений ragent (-seclev): 0 — без защиты,
          1 — защищено только при аутентификации, 2 — защищено всё
          соединение. 0 оставлен по умолчанию ради совместимости; для
          рабочих серверов рассмотрите 2.
        '';
      };
      range = mkOption {
        type = types.strMatching "[1-9][0-9]*:[1-9][0-9]*(,[1-9][0-9]*:[1-9][0-9]*)*";
        default = "1560:1591";
        example = "1560:1591,1600:1610";
        description = "Диапазоны портов рабочих процессов (-range).";
      };
      pingPeriod = mkOption {
        type = types.ints.positive;
        default = 1000;
        description = "Период контроля соединений между процессами кластера, мс (-pingPeriod).";
      };
      pingTimeout = mkOption {
        type = types.ints.positive;
        default = 5000;
        description = "Таймаут контроля соединений, мс (-pingTimeout).";
      };
      debug = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Запустить сервер с отладкой (-debug -http). Сервер отладки не
          требует аутентификации: только для доверенной сети.
        '';
      };
      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Дополнительные аргументы ragent.";
      };
      openFirewall = mkOption {
        type = types.bool;
        default = false;
        description = "Открыть port, regport и range в файрволе.";
      };
      allowInsecureNetwork = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Разрешить openFirewall при securityLevel = 0, то есть
          нешифрованные соединения с кластером из сети. Без этой опции
          такое сочетание — ошибка конфигурации.
        '';
      };
    };

    ras = {
      enable = mkEnableOption "сервер администрирования 1С (ras) для rac и консолей";
      port = mkOption {
        type = types.port;
        default = 1545;
        description = "Порт ras.";
      };
      agentAddress = mkOption {
        type = types.str;
        default = "localhost:${toString cfg.server.port}";
        defaultText = lib.literalExpression ''"localhost:''${toString config.services.onec.server.port}"'';
        example = "192.168.1.100:1540";
        description = "Адрес агента сервера (ragent), который обслуживает ras.";
      };
      openFirewall = mkOption {
        type = types.bool;
        default = false;
        description = "Открыть порт ras в файрволе.";
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.onec.package = pkg;

      assertions = [
        {
          assertion = o == "1cv8t" -> !(cfg.server.enable || cfg.ras.enable);
          message = ''
            services.onec: в учебной версии (/opt/1cv8t) нет сервера 1С и RAS —
            отключите server.enable и ras.enable или возьмите дистрибутив
            «Технологическая платформа 1С:Предприятия (64-bit) для Linux».
          '';
        }
        {
          assertion =
            cfg.server.enable && cfg.server.openFirewall && cfg.server.securityLevel == 0
            -> cfg.server.allowInsecureNetwork;
          message = ''
            services.onec: server.openFirewall при server.securityLevel = 0 открывает
            в сеть нешифрованные соединения с кластером. Задайте securityLevel = 2
            или, если сеть доверенная, server.allowInsecureNetwork = true.
          '';
        }
        {
          assertion =
            let
              sorted = lib.sort (a: b: a.from < b.from) portRanges;
              at = builtins.elemAt sorted;
            in
            cfg.server.enable
            ->
              lib.all (r: r.from >= 1 && r.from <= r.to && r.to <= 65535) portRanges
              && lib.all (i: (at i).to < (at (i + 1)).from) (lib.range 0 (lib.length sorted - 2));
          message = ''
            services.onec: server.range = "${cfg.server.range}" — каждый диапазон
            должен быть вида «начало:конец», 1 ≤ начало ≤ конец ≤ 65535, и
            диапазоны не должны пересекаться.
          '';
        }
      ];

      warnings =
        let
          noAdmin = ''
            Пока администратор кластера не задан (так сразу после установки),
            кластером может управлять любой, кто достучится до портов ${toString cfg.server.port}
            и ${toString cfg.ras.port}: задайте администратора (rac cluster admin register).'';
        in
        optional (cfg.server.enable && cfg.server.openFirewall && cfg.server.securityLevel == 0) ''
          services.onec: server.openFirewall открывает порты ${toString cfg.server.port}, ${toString cfg.server.regport}
          и ${cfg.server.range} в сеть при server.securityLevel = 0 — соединения не
          шифруются. Рассмотрите securityLevel = 2. ${noAdmin}''
        ++ optional (
          cfg.ras.enable && cfg.ras.openFirewall
        ) "services.onec: ras.openFirewall открывает порт ras (${toString cfg.ras.port}) в сеть. ${noAdmin}"
        ++
          optional (cfg.server.enable && cfg.server.securityLevel == 0 && !config.networking.firewall.enable)
            ''
              services.onec: файрвол выключен, и порты ragent доступны из сети при
              server.securityLevel = 0 — соединения не шифруются. Рассмотрите
              securityLevel = 2. ${noAdmin}''
        ++ optional (cfg.server.enable && cfg.server.debug) ''
          services.onec: server.debug поднимает сервер отладки без аутентификации —
          только для доверенной сети.'';

      # Через строку: путь вне стора (src = ./архив) так тоже попадает в стор,
      # а extraDependencies принимает только пути из стора.
      system.extraDependencies = optional cfg.keepSrc "${cfg.src}";

      # Ссылки /opt/<o>/{x86_64,common} ставит отдельная служба, а не
      # «L+» systemd-tmpfiles: «L+» рекурсивно удаляет каталог на месте
      # ссылки, в том числе установку 1С штатным инсталлятором. Не скрипт
      # активации: с system.nixos-init.enable они не выполняются, а ошибка
      # службы видна в systemctl --failed.
      systemd.services.onec-opt-link = mkIf cfg.linkToOpt {
        description = "Link 1C:Enterprise ${pkg.version} into /opt/${o}";
        wantedBy = [ "multi-user.target" ];
        unitConfig.RequiresMountsFor = "/opt";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${optLinkScript}";
        };
      };

      systemd.tmpfiles.rules =
        optionals cfg.linkToOpt [
          "d /opt/${o} 0755 root root -"
          # Общий conf.cfg платформы: копия, чтобы его можно было править
          # (уже существующий файл не перезаписывается).
          "d /opt/${o}/conf 0755 root root -"
          "C /opt/${o}/conf/conf.cfg - - - - ${pkg.optRoot}/${o}/conf/conf.cfg"
          "z /opt/${o}/conf/conf.cfg 0644 root root -"
        ]
        ++ optionals cfg.licensesDir.enable [
          "d /var/1C 0755 root root -"
          "d /var/1C/licenses ${cfg.licensesDir.mode} root ${licGroup} -"
        ];
    }

    (mkIf cfg.licensesDir.enable {
      users.groups.${licGroup} = { };
      users.users = lib.genAttrs cfg.licensesDir.users (_: {
        extraGroups = [ licGroup ];
      });
    })

    (mkIf cfg.client.enable {
      environment.systemPackages = [ pkg ];
      fonts.packages = optional cfg.client.fonts pkgs.corefonts;
    })

    (mkIf (cfg.server.enable || cfg.ras.enable) {
      users.users.${cfg.server.user} = mkMerge [
        (mkIf (cfg.server.user == defaultUser) {
          isSystemUser = true;
          group = cfg.server.group;
          home = cfg.server.dataDir;
          createHome = true;
          description = "1C Enterprise server";
        })
        {
          extraGroups = optional (cfg.licensesDir.enable && licGroup != cfg.server.group) licGroup;
        }
      ];
      users.groups.${cfg.server.group} = mkIf (cfg.server.group == defaultGroup) { };
      # Свой пользователь может жить где угодно — каталог данных создаём сами.
      systemd.tmpfiles.rules = optional (
        cfg.server.user != defaultUser
      ) "d ${cfg.server.dataDir} 0750 ${cfg.server.user} ${cfg.server.group} -";
      environment.systemPackages = [ pkg ]; # rac, ibcmd и др. для администратора
    })

    (mkIf cfg.server.enable {
      systemd.services."1c-ragent" = lib.recursiveUpdate serverUnitCommon {
        description = "1C:Enterprise ${pkg.version} server agent";
        serviceConfig.ExecStart = lib.escapeShellArgs (
          [
            "${pkg}/bin/ragent"
            "-d"
            cfg.server.dataDir
            "-port"
            (toString cfg.server.port)
            "-regport"
            (toString cfg.server.regport)
            "-range"
            cfg.server.range
            "-seclev"
            (toString cfg.server.securityLevel)
            "-pingPeriod"
            (toString cfg.server.pingPeriod)
            "-pingTimeout"
            (toString cfg.server.pingTimeout)
          ]
          ++ optionals cfg.server.debug [
            "-debug"
            "-http"
          ]
          ++ cfg.server.extraArgs
        );
      };

      networking.firewall = mkIf cfg.server.openFirewall {
        allowedTCPPorts = [
          cfg.server.port
          cfg.server.regport
        ];
        allowedTCPPortRanges = portRanges;
      };
    })

    (mkIf cfg.ras.enable {
      systemd.services."1c-ras" = lib.recursiveUpdate serverUnitCommon {
        description = "1C:Enterprise ${pkg.version} remote administration server";
        after = [ "network-online.target" ] ++ optional cfg.server.enable "1c-ragent.service";
        requires = optional cfg.server.enable "1c-ragent.service";
        serviceConfig.ExecStart = lib.escapeShellArgs [
          "${pkg}/bin/ras"
          "cluster"
          "--port=${toString cfg.ras.port}"
          cfg.ras.agentAddress
        ];
      };
      networking.firewall.allowedTCPPorts = mkIf cfg.ras.openFirewall [ cfg.ras.port ];
    })
  ]);
}
