{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.auth-scope-agent;
in {
  options.services.auth-scope-agent = {
    enable = lib.mkEnableOption "Auth-Scope Agent";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The auth-scope package to use.";
    };

    settings = lib.mkOption {
      type = (pkgs.formats.json {}).type;
      default = {};
      description = "Configuration for the agent (mapped directly to agent.json).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [cfg.package];

    environment.etc."auth-scope/agent.json".source =
      (pkgs.formats.json {}).generate "agent.json" cfg.settings;

    systemd.services.auth-scope-agent = {
      description = "Auth-Scope Agent";
      wantedBy = ["multi-user.target"];
      after = ["auth-scope-server.service"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${cfg.package}/bin/auth-scope-agent --config /etc/auth-scope/agent.json";
        RemainAfterExit = true;
      };
    };
  };
}
