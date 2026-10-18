{
  description = "1С:Предприятие 8.3 для Nix/NixOS — пакет и модуль. Дистрибутив не входит: его приносит пользователь";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      tests = import ./tests { inherit pkgs nixpkgs self; };
    in
    {
      lib = {
        # Собрать платформу: inputs.onec.lib.mkOnec pkgs { src = ...; }
        mkOnec = pkgs: args: pkgs.callPackage ./pkgs/onec args;

        # Проверка собранной платформы на настоящем дистрибутиве
        # (см. tests/run-integration.sh). В flake check не входит.
        mkIntegrationTest = pkgs: onec: import ./tests/integration.nix { inherit pkgs onec; };

        # Ссылка на дистрибутив, который пользователь сам положил в стор.
        # Положить в стор: nix store add --mode flat ~/Downloads/<файл>
        # Хеш:            nix hash file ~/Downloads/<файл>
        requireDist =
          pkgs:
          { name, hash }:
          pkgs.requireFile {
            inherit name hash;
            message = ''

              Дистрибутив 1С не скачивается автоматически и не распространяется
              этим репозиторием. Скачайте «${name}» со своего аккаунта на
              https://releases.1c.ru (учебную версию — бесплатно на
              https://online.1c.ru/catalog/free/) и добавьте его в стор:

                nix store add --mode flat /путь/к/${name}

              («nix store add» без --mode flat добавит файл как NAR, и путь
              не совпадёт с ожидаемым. «nix store add-file» тоже подходит,
              но в новых версиях Nix помечен устаревшим.)

              После nix-collect-garbage команду придётся повторить.
            '';
          };
      };

      nixosModules = {
        default = ./modules/onec.nix;
        onec = ./modules/onec.nix;
      };

      # NixOS-тест в QEMU тяжёлый — отдельно от быстрых проверок:
      # nix build .#module-vm-test -L
      checks.${system} = removeAttrs tests [ "module-vm" ];
      packages.${system}.module-vm-test = tests.module-vm;

      formatter.${system} = pkgs.nixfmt;
    };
}
