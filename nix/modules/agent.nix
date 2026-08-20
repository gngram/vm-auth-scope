{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.auth-scope.agent;
  shared = config.services.auth-scope;
in {
  options.services.auth-scope.agentPort = lib.mkOption {
    type = lib.types.port;
    default = 901;
    description = "The vsock port the agent binds/dials from.";
  };

  options.services.auth-scope.agent = {
    enable = lib.mkEnableOption "Auth-Scope Agent";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The auth-scope package to use.";
    };

    settings = lib.mkOption {
      type = (pkgs.formats.json {}).type;
      default = {};
      description = "Configuration for the agent, mapped directly to `agent.json`. Detailed documentation is available at [docs/agent_configuration.md](../../docs/agent_configuration.md) and sample file at [config-examples/agent.json](../../config-examples/agent.json).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [cfg.package];

    services.udev.extraRules = ''
      KERNEL=="vsock", TAG+="systemd"
    '';

    environment.etc."auth-scope/agent.json".source =
      (pkgs.formats.json {}).generate "agent.json" ({
        vm_name = config.networking.hostName;
      } // cfg.settings // {
        client_port = shared.agentPort;
      });

    systemd.services.auth-scope-agent = {
      description = "Auth-Scope Agent";
      # Anchor to early boot instead of normal multi-user startup
      wantedBy = [ "sysinit.target" ];
      unitConfig = {
        DefaultDependencies = false;
      };
      bindsTo = [ "dev-vsock.device" ];
      after = [ "dev-vsock.device" ];
      before = [ "sysinit.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${cfg.package}/bin/auth-scope-agent --config /etc/auth-scope/agent.json";
        RemainAfterExit = true;
      };
    };
  };
}
