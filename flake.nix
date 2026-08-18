{
  description = "Auth-Scope NixOS VM Test";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {inherit system;};

    authScope = pkgs.rustPlatform.buildRustPackage {
      pname = "auth-scope";
      version = "0.1.0";
      src = ./.;
      cargoLock.lockFile = ./Cargo.lock;
      doCheck = false;
    };
  in {
    nixosModules.default = ./nixos;

    devShells.${system}.default = import ./develop.nix {inherit pkgs;};

    checks.${system}.vm-test = import ./test/vm-test.nix {
      inherit pkgs;
      nixosModules = self.nixosModules;
      inherit authScope;
    };
  };
}
