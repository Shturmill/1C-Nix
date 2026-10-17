# Библиотеки, которые платформа 1С ожидает найти в системе, по профилям:
#   common — нужно всем бинарникам (сервер, rac, ibcmd, клиенты);
#   server — кластер (ragent/rphost): шрифты и растр для печатных форм,
#            PDF и картинок, но без GTK/WebKit/X11;
#   client — графические клиенты (1cv8, 1cv8c, 1cestart): GTK, WebKit, CUPS.
#
# Если бинарник падает с «error while loading shared libraries: libXXX»,
# найдите пакет (nix-locate libXXX) и добавьте сюда или в extraPkgs.
# Посмотреть недостающее: `onec-shell -c 'ldd /opt/.../1cv8c | grep "not found"'`.
pkgs:
let
  # X11: в nixpkgs-unstable набор xorg.* переименован (xorg.libX11 -> libx11),
  # в стабильных ветках — ещё старые имена. Берём то, что есть.
  x11 = map (n: pkgs.${n.new} or pkgs.xorg.${n.old}) [
    {
      new = "libx11";
      old = "libX11";
    }
    {
      new = "libxext";
      old = "libXext";
    }
    {
      new = "libxrender";
      old = "libXrender";
    }
    {
      new = "libxtst";
      old = "libXtst";
    }
    {
      new = "libxi";
      old = "libXi";
    }
    {
      new = "libxrandr";
      old = "libXrandr";
    }
    {
      new = "libxcursor";
      old = "libXcursor";
    }
    {
      new = "libxcomposite";
      old = "libXcomposite";
    }
    {
      new = "libxdamage";
      old = "libXdamage";
    }
    {
      new = "libxfixes";
      old = "libXfixes";
    }
    {
      new = "libxinerama";
      old = "libXinerama";
    }
    {
      new = "libsm";
      old = "libSM";
    }
    {
      new = "libice";
      old = "libICE";
    }
    {
      new = "libxxf86vm";
      old = "libXxf86vm";
    } # libwx_gtk3u_gl
  ];
in
{
  common = [
    pkgs.stdenv.cc.cc.lib # libstdc++ / libgcc_s вместо бандловых
    pkgs.glibc
    pkgs.zlib
    pkgs.util-linux.lib # libuuid
    pkgs.e2fsprogs # libcom_err
    pkgs.krb5 # libgssapi_krb5 (Kerberos-аутентификация)
    (pkgs.unixodbc or pkgs.unixODBC)
    pkgs.libxml2
    pkgs.openssl
    pkgs.curl
    pkgs.glib
  ];

  server = [
    pkgs.fontconfig
    pkgs.freetype
    pkgs.cairo
    pkgs.pango
    pkgs.harfbuzz
    pkgs.libpng
    pkgs.libjpeg
    pkgs.libtiff
  ];

  client = [
    # графика и GTK
    pkgs.gtk3
    pkgs.cairo
    pkgs.pango
    pkgs.harfbuzz
    pkgs.gdk-pixbuf
    pkgs.atk
    pkgs.at-spi2-atk
    pkgs.at-spi2-core
    pkgs.fontconfig
    pkgs.freetype
    pkgs.libpng
    pkgs.libjpeg
    pkgs.libtiff
    pkgs.libGL
    pkgs.libGLU
    pkgs.libxkbcommon
    pkgs.dbus
    pkgs.gsettings-desktop-schemas
    pkgs.adwaita-icon-theme

    # печать: 1cv8, 1cv8c и uiproxy линкуются с libcups.so.2 напрямую
    pkgs.cups.lib

    # встроенный браузер (HTML-поля, справка, веб-формы)
    pkgs.webkitgtk_4_1
    pkgs.libsoup_3
    pkgs.libsecret
    pkgs.gst_all_1.gstreamer
    pkgs.gst_all_1.gst-plugins-base

    # шрифты, на которые рассчитаны печатные формы
    pkgs.corefonts
  ]
  ++ x11;
}
