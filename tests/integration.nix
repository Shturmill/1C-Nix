# Проверка на НАСТОЯЩЕМ дистрибутиве 1С. В публичном CI не запускается:
# дистрибутив проприетарный. Запуск: tests/run-integration.sh <архив>.
#
# Что проверяется (то, чего не видят тесты на фальшивках):
#   1. каждый исполняемый ELF платформы находит все lib*.so в FHS-окружении;
#   2. платформа реально стартует: создание файловой ИБ (GTK, локаль);
#   3. Конфигуратор в пакетном режиме (DESIGNER /DumpCfg);
#   4. тонкий клиент открывает базу и не падает за 20 секунд;
#   5. 1cestart запускается и не падает.
# Пункты 3–5 по умолчанию только для учебной версии: обычной платформе без
# лицензии запуск Конфигуратора и клиента не разрешён.
{
  pkgs,
  onec,
  runClients ? onec.optName == "1cv8t",
}:

let
  t = pkgs.lib.optionalString (onec.optName == "1cv8t") "t";

  # Шаги 2–5 идут в одном Xvfb. Каждый запуск 1С — под timeout: зависший
  # процесс роняет проверку, а не вешает её. В песочнице сборки такое
  # зависание при старте 1cv8t изредка наблюдалось.
  steps = pkgs.writeShellScript "onec-integration-steps" ''
    set -eu
    PATH=${
      pkgs.lib.makeBinPath [
        pkgs.procps
        pkgs.coreutils
      ]
    }:$PATH

    # run <метка> <секунд> <ожидание: exit|alive> <команда…>
    # exit — процесс должен сам завершиться с кодом 0 за <секунд>;
    # alive — должен проработать все <секунд> (timeout вернёт 124, или 137,
    # если на TERM не ответил и добит KILL). Это проверка «не упал», а не
    # «GUI отвечает».
    run() {
      tag=$1 limit=$2 expect=$3; shift 3
      rc=0
      timeout --signal=TERM --kill-after=3s "''${limit}s" "$@" \
        < /dev/null > "$TMPDIR/$tag.out" 2>&1 || rc=$?
      pkill -f "$TMPDIR/ib" || true
      case "$expect:$rc" in
        exit:0 | alive:124 | alive:137) return 0 ;;
      esac
      case "$expect:$rc" in
        exit:124 | exit:137) echo "$tag: не завершился за $limit с" >&2 ;;
        *) echo "$tag: код завершения $rc (ожидалось: $expect)" >&2 ;;
      esac
      cat "$TMPDIR/$tag.out" >&2
      return 1
    }

    echo "== 2. создание информационной базы"
    run create 180 exit ${onec}/bin/1cv8${t} CREATEINFOBASE "File=$TMPDIR/ib" \
      /Out "$TMPDIR/create.log" /DisableStartupDialogs
    cat "$TMPDIR/create.log" || true
    test -s "$TMPDIR/ib/1Cv8.1CD"

    if [ -n "${pkgs.lib.optionalString runClients "1"}" ]; then
      echo "== 3. Конфигуратор: выгрузка конфигурации"
      run designer 180 exit ${onec}/bin/1cv8${t} DESIGNER /F "$TMPDIR/ib" \
        /DumpCfg "$TMPDIR/dump.cf" /Out "$TMPDIR/designer.log" /DisableStartupDialogs
      cat "$TMPDIR/designer.log" || true
      test -s "$TMPDIR/dump.cf"

      echo "== 4. тонкий клиент"
      run thin 20 alive ${onec}/bin/1cv8c${t} /F "$TMPDIR/ib" /DisableStartupDialogs

      echo "== 5. 1cestart"
      run starter 10 alive ${onec}/bin/1cestart${t}
    fi
  '';
in
pkgs.runCommand "onec-integration-${onec.version}"
  {
    nativeBuildInputs = [ pkgs.xvfb-run ];
  }
  ''
    set -eu
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"

    echo "== 1. разрешение библиотек"
    ${onec}/bin/onec-shell -c '
      fail=0
      for f in ${onec.dist}/opt/*/x86_64/*/* ${onec.dist}/opt/*/common/*; do
        [ -f "$f" ] && [ -x "$f" ] || continue
        head -c4 "$f" | grep -q ELF || continue
        miss="$(ldd "$f" 2>&1 | grep "not found" || true)"
        if [ -n "$miss" ]; then echo "$f:"; echo "$miss"; fail=1; fi
      done
      exit $fail'

    xvfb-run -a -s "-screen 0 1280x800x24" ${steps}

    echo "== всё в порядке"
    touch "$out"
  ''
