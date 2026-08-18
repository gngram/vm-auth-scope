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
  ];

  shellHook = ''
    alias run-test="nix build .#checks.''${pkgs.stdenv.hostPlatform.system}.vm-test --print-build-logs"
  '';
}
