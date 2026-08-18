{pkgs}:
pkgs.mkShell {
  buildInputs = with pkgs; [
    cargo
    rustc
    gcc
    pkg-config
    rustfmt
    clippy
    alejandra
    qemu
    go
  ];

  shellHook = ''
    clear
    alias run-integration-test="sudo ./scripts/run_integration_test.sh"
    alias run-nixos-module-test='nix build .#checks.\${pkgs.stdenv.hostPlatform.system}.vm-test --print-build-logs'
    echo -e "\n\033[1;32m            -- development shell for vm-auth-scope -- \033[0m\n"
    echo -e "\033[1;33mCommands:\033[0m"
    echo -e "\033[1;34mrun-integration-test:\033[0m    Execute the test suite for integration verification."
    echo -e "\033[1;34mrun-nixos-module-test:\033[0m   Execute NixOS tests to validate system modules."
    echo -e "\033[1;32m                                 --- \033[0m\n"
    export PS1="\[\033[1;32m\][DEVELOP]\[\033[0m\] $PS1"
  '';
}
