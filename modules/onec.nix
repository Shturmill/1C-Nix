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
      preferWebkit41
      dropBundledLibs
      extraPkgs
      ;
    inherit (cfg.client) scale;
    enableX11Fixes = cfg.client.x11Fixes.enable;
  };

  o = pkg.optName;
  licGroup = cfg.licensesDir.group;

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
      # Без RestrictNamespaces/NoNewPrivileges-ограничений userns:
      # бинарники 1С запускаются через bubblewrap.
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
      type = types.listOf types.str;
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
        (через systemd-tmpfiles). Нужно 1cestart для поиска версий,
        а также внешним инструментам — 1C:EDT, vanessa-runner и т.п.
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

    licensesDir = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Создать /var/1C/licenses для программных лицензий.";
      };
      group = mkOption {
        type = types.str;
        default = cfg.server.group;
        defaultText = lib.literalExpression "config.services.onec.server.group";
        description = ''
          Группа-владелец /var/1C/licenses. Активировать и использовать
          программные лицензии могут root и члены этой группы.
        '';
      };
      mode = mkOption {
        type = types.str;
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
          1С под X11/XWayland (pkgs/onec/x11-fixes.c). На один запуск
          отключается без пересборки: `ONEC_NO_X11_FIXES=1 1cv8`.
        '';
      };
    };

    server = {
      enable = mkEnableOption "кластер серверов 1С (ragent)";
      user = mkOption {
        type = types.str;
        default = "usr1cv8";
        description = "Пользователь сервера 1С.";
      };
      group = mkOption {
        type = types.str;
        default = "grp1cv8";
        description = "Группа сервера 1С.";
      };
      dataDir = mkOption {
        type = types.path;
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
        type = types.str;
        default = "1560:1591";
        description = "Диапазон портов рабочих процессов.";
      };
      debug = mkOption {
        type = types.bool;
        default = false;
        description = "Запустить сервер с отладкой (-debug -http).";
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
      ];

      systemd.tmpfiles.rules =
        optionals cfg.linkToOpt [
          "d /opt/${o} 0755 root root -"
          "d /opt/${o}/x86_64 0755 root root -"
          "L+ /opt/${o}/x86_64/${pkg.version} - - - - ${pkg.optRoot}/${o}/x86_64/${pkg.version}"
          "L+ /opt/${o}/common - - - - ${pkg.optRoot}/${o}/common"
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
      users.users.${cfg.server.user} = {
        isSystemUser = true;
        group = cfg.server.group;
        home = cfg.server.dataDir;
        createHome = true;
        description = "1C:Enterprise server";
        extraGroups = optional (cfg.licensesDir.enable && licGroup != cfg.server.group) licGroup;
      };
      users.groups.${cfg.server.group} = { };
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
            "1000"
            "-pingTimeout"
            "5000"
          ]
          ++ optionals cfg.server.debug [
            "-debug"
            "-http"
          ]
          ++ cfg.server.extraArgs
        );
      };

      networking.firewall = mkIf cfg.server.openFirewall (
        let
          parts = lib.splitString ":" cfg.server.range;
        in
        {
          allowedTCPPorts = [
            cfg.server.port
            cfg.server.regport
          ];
          allowedTCPPortRanges = [
            {
              from = lib.toInt (builtins.elemAt parts 0);
              to = lib.toInt (builtins.elemAt parts 1);
            }
          ];
        }
      );
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
