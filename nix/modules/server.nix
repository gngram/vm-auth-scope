{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.auth-scope.server;
  shared = config.services.auth-scope;
in {
  options.services.auth-scope.serverPort = lib.mkOption {
    type = lib.types.port;
    default = 900;
    description = "The vsock port the server listens on.";
  };

  options.services.auth-scope.server = {
    enable = lib.mkEnableOption "Auth-Scope Server";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The auth-scope package to use.";
    };

    settings = lib.mkOption {
      type = (pkgs.formats.json {}).type;
      default = {};
      description = "Configuration for the server, mapped directly to `host.json`. Detailed documentation is available at [docs/server_configuration.md](../../docs/server_configuration.md) and sample file at [config-examples/host.json](../../config-examples/host.json).";
    };

    generateKey = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to generate the CA key on startup (using --genkey).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [cfg.package];

    services.udev.extraRules = ''
      KERNEL=="vsock", TAG+="systemd"
    '';

    environment.etc."auth-scope/host.json".source =
      (pkgs.formats.json {}).generate "host.json" (cfg.settings // {
        server_port = shared.serverPort;
      });

    systemd.services.auth-scope-server = {
      description = "Auth-Scope Host Server";
      wantedBy = [ "sysinit.target" ];
      unitConfig = {
        DefaultDependencies = false;
      };
      bindsTo = [ "dev-vsock.device" ];
      after = [ "dev-vsock.device" ];
      before = [ "sysinit.target" ];
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/auth-scope-server --config /etc/auth-scope/host.json${lib.optionalString cfg.generateKey " --genkey"}";
        Restart = "always";
      };
    };
  };
}
