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

    authScope = pkgs.callPackage ./nix/pkgs/auth-scope-rust.nix {};
    authScopeGo = pkgs.callPackage ./nix/pkgs/auth-scope-go.nix {};
  in {
    nixosModules.default = ./nix/modules/auth-scope.nix;

    devShells.${system}.default = import ./nix/develop.nix {inherit pkgs;};

    checks.${system}.vm-test = import ./nix/checks/vm-test.nix {
      inherit pkgs;
      nixosModules = self.nixosModules;
      inherit authScope authScopeGo;
    };
  };
}
