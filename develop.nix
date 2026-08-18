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
  ];

  shellHook = ''
    alias run-test="sudo ./run_integration_test.sh"
  '';
}
