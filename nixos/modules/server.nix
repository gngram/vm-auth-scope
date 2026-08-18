{ config, lib, pkgs, ... }:
let
  cfg = config.services.auth-scope-server;
in {
  options.services.auth-scope-server = {
    enable = lib.mkEnableOption "Auth-Scope Server";
    
    package = lib.mkOption {
      type = lib.types.package;
      description = "The auth-scope package to use.";
    };
    
    settings = lib.mkOption {
      type = (pkgs.formats.json {}).type;
      default = {};
      description = "Configuration for the server (mapped directly to host.json).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    environment.etc."auth-scope/host.json".source = 
      (pkgs.formats.json {}).generate "host.json" cfg.settings;

    systemd.services.auth-scope-server = {
      description = "Auth-Scope Host Server";
      wantedBy = [ "multi-user.target" ];
      preStart = ''
        ${cfg.package}/bin/auth-scope-server --init --config /etc/auth-scope/host.json
      '';
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/auth-scope-server --config /etc/auth-scope/host.json";
        Restart = "always";
      };
    };
  };
}
