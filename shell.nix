{ pkgs, spago2nix, projectEnv, deploy-rs, sopsHook, litestream, bootstrapSrc }:
let

  lions-dummy = pkgs.writeScriptBin "lions-dummy" ''
    #!${pkgs.fish}/bin/fish
    for f in ./dev/*; sqlite3 $LIONS_SQLITE_PATH < $f; end
  '';

  lions-ghcid = pkgs.writeScriptBin "lions-ghcid" ''
    #!/bin/sh
    ghcid --no-height-limit --clear --reverse
  '';

  # If needed can also just forward arguments to sass here
  # TODO: Properly handle permissions for out path.
  # The things that "nix build" creates are put in the Nix store and then a
  # symlink to the folder in the store is created. That means I can't have Nix
  # be in charge of "public" while also optionally letting "sass --watch" write
  # to the store. I can modify dev.hs though so create the public folder, build
  # the Nix stuff into "result" and then symlink everything inside "result/*"
  # into public. That way "sass" (or any process running under my user) should
  # be able to write into "public/"
  lions-sass = pkgs.writeScriptBin "lions-sass" ''
    #!/bin/sh
    ${pkgs.nodePackages.sass}/bin/sass --watch --load-path=${bootstrapSrc} ./client/sass/styles.scss public/style.css
  '';

  # Need --impure so I can use getEnv in nix build
  lions-vm = pkgs.writeShellScriptBin "lions-vm" ''
    nix build --impure .#vm
    echo "visit https://localhost:8081/"
    echo "or http://localhost:8080/"
    export QEMU_NET_OPTS="hostfwd=tcp::2221-:22,hostfwd=tcp::8080-:80,hostfwd=tcp::8081-:443"
    ./result/bin/run-nixos-vm
  '';

  lions-vm-db = pkgs.writeShellScriptBin "lions-vm-db" ''
    scp -P 2221 $LIONS_SQLITE_PATH root@localhost:/var/lib/lions-server/db
  '';

  spago2nix' = import spago2nix { inherit pkgs; };

in
pkgs.mkShell {
  sopsPGPKeyDirs = [
    "./keys/hosts"
    "./keys/users"
  ];
  inputsFrom = [ projectEnv ];
  nativeBuildInputs = [
    sopsHook
    spago2nix'
  ];
  buildInputs = with pkgs.haskellPackages;
    [
      # Haskell
      ghcid
      ormolu
      hlint
      cabal2nix
      haskell-language-server
      cabal-install
      cabal-fmt
      fast-tags
      hoogle

      pkgs.nixpkgs-fmt

      # Database
      pkgs.go-migrate
      pkgs.sqlite-interactive
      pkgs.sqlite-web
      litestream

      # Purescript
      pkgs.purescript
      pkgs.spago
      pkgs.nodePackages.pscid
      pkgs.nodePackages.purescript-language-server
      pkgs.nodePackages.purty

      # Scripts
      pkgs.bash_5
      pkgs.jq
      pkgs.parallel
      lions-vm
      lions-ghcid
      lions-dummy
      lions-vm-db

      # Infra
      # This doesn't work on NixOS because of yet another fucking NPM package
      # that tries to reimplement an OS package manager and downloads random
      # binaries from the internet. The problem here is `node-re2`. I really
      # hate NPM and Javascript. https://github.com/uhop/node-re2/issues/107
      # pkgs.nodePackages.firebase-tools
      pkgs.terraform_0_15
      pkgs.cli53
      pkgs.nodePackages.sass
      pkgs.packer
      pkgs.awscli2
      deploy-rs
    ];
}
