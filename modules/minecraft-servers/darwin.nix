{
  config,
  lib,
  options,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.services.minecraft-servers;

  normalizeFiles = files: mapAttrs configToPath (filterAttrs (_: nonEmptyValue) files);
  nonEmptyValue = x: nonEmpty x && (x ? value -> nonEmpty x.value);
  nonEmpty = x: x != { } && x != [ ];

  configToPath =
    name: config:
    if isStringLike config then config else (getFormat name config).generate name config.value;
  getFormat =
    name: config: if config ? format && config.format != null then config.format else inferFormat name;
  inferFormat =
    name:
    let
      error = throw "nix-minecraft: Could not infer format from file '${name}'. Specify one using 'format'.";
      extension = builtins.match "[^.]*\\.(.+)" name;
    in
    if extension != null && extension != [ ] then
      formatExtensions.${head extension} or error
    else
      error;

  txtList =
    { }:
    {
      type = with lib.types; listOf str;
      generate = name: value: pkgs.writeText name (lib.concatStringsSep "\n" value);
    };

  formatExtensions = with pkgs.formats; {
    "yml" = yaml { };
    "yaml" = yaml { };
    "json" = json { };
    "props" = keyValue { };
    "properties" = keyValue { };
    "toml" = toml { };
    "ini" = ini { };
    "txt" = txtList { };
  };

  # Darwin-only managementSystemConfig: no systemd-socket support
  managementSystemConfig =
    name: server:
    let
      ms = server.managementSystem;
      tmux = "${getBin pkgs.tmux}/bin/tmux";
    in
    assert assertMsg (
      !(ms.tmux.enable && ms.systemd-socket.enable)
    ) "Only one server management system can be enabled at a time.";
    if ms.tmux.enable then
      let
        sock = ms.tmux.socketPath name;
      in
      {
        managementType = "tmux";
        start = ''
          ${tmux} -S ${sock} new -d ${getExe server.package} ${server.jvmOpts}

          ${pkgs.coreutils}/bin/chmod 660 ${sock}
        '';
        stop = ''
          if ${tmux} -S ${sock} has-session 2>/dev/null; then
            ${tmux} -S ${sock} send-keys C-u ${escapeShellArg server.stopCommand} Enter
            while ${tmux} -S ${sock} has-session 2>/dev/null; do sleep 1s; done
          fi
        '';
      }
    else if ms.systemd-socket.enable then
      builtins.throw ''
        nix-minecraft: systemd-socket management is not supported on Darwin.
        Only tmux management is available on macOS. Set `managementSystem.systemd-socket.enable = false`
        and `managementSystem.tmux.enable = true` for all servers.
      ''
    else
      builtins.throw "At least one server management system must be enabled.";

  servers = filterAttrs (_: cfg: cfg.enable) cfg.servers;
in
{
  imports = [ ./common.nix ];

  config = mkIf cfg.enable (mkMerge [
    # Darwin-specific assertions
    {
      assertions = [
        {
          assertion = lib.all (name: conf: !conf.managementSystem.systemd-socket.enable) (
            lib.mapAttrsToList lib.nameValuePair servers
          );
          message = ''
            nix-minecraft on Darwin: Some servers use `systemd-socket` management,
            which is not supported on macOS. Only `tmux` management mode is available.
            Set `services.minecraft-servers.servers.<name>.managementSystem.systemd-socket.enable = false`
            and `...managementSystem.tmux.enable = true` for affected servers.
          '';
        }
      ];
    }

    {
      warnings =
        lib.optional (lib.any (n: conf: conf.enableReload) (lib.mapAttrsToList lib.nameValuePair servers))
          ''
            nix-minecraft on Darwin: `enableReload` and `extraReload` have no effect on macOS.
            launchd does not support config-change-triggered reloads (`restartIfChanged` / `reloadIfChanged`).
            To apply config changes, restart the service manually with:
              sudo launchctl kickstart -k system/org.nixos.minecraft-server-<name>
          '';
    }

    # Darwin user/group management (different attribute set from NixOS)
    {
      users.knownUsers = mkIf (cfg.user == "minecraft") [ "minecraft" ];
      users.knownGroups = mkIf (cfg.group == "minecraft") [ "minecraft" ];

      users.users.minecraft = mkIf (cfg.user == "minecraft") {
        uid = 493;
        gid = 493;
        isHidden = true;
      };

      users.groups.minecraft = mkIf (cfg.group == "minecraft") {
        gid = 493;
      };
    }

    # Darwin has no /run tmpfs. Default tmux sockets under data dir.
    {
      services.minecraft-servers.managementSystem.tmux.socketPath = lib.mkDefault (
        name: "${cfg.dataDir}/${name}/tmux.sock"
      );
    }

    # Darwin does not have systemd.tmpfiles.rules.
    # Use postActivation to create data directories after users/groups exist.
    {
      system.activationScripts.postActivation.text = lib.mkAfter (
        concatMapStringsSep "\n" (name: ''
          install -d -m 0770 -o ${cfg.user} -g ${cfg.group} '${cfg.dataDir}/${name}'
          install -d -m 0770 -o ${cfg.user} -g ${cfg.group} '${cfg.dataDir}/${name}/logs'
        '') (attrNames servers)
      );
    }

    # macOS application-level firewall is not port-based, so we skip port opening.
    # Users should manage firewall rules through macOS System Settings if needed.

    # launchd daemons for each server
    {
      launchd.daemons = mapAttrs' (
        name: conf:
        let
          symlinks = normalizeFiles (
            {
              "eula.txt".value = {
                eula = true;
              };
              "eula.txt".format = pkgs.formats.keyValue { };
            }
            // conf.symlinks
          );
          files = normalizeFiles (
            {
              "whitelist.json".value = mapAttrsToList (n: v: {
                name = n;
                uuid = v;
              }) conf.whitelist;
              "ops.json".value = mapAttrsToList (n: v: {
                name = n;
                uuid = v.uuid;
                level = v.level;
                bypassesPlayerLimit = v.bypassesPlayerLimit;
              }) conf.operators;
              "banned-players.json".value = mapAttrsToList (
                n: v:
                {
                  name = n;
                  uuid = v.uuid;
                }
                // lib.optionalAttrs (v.created != null) {
                  created = v.created;
                }
                // lib.optionalAttrs (v.source != null) {
                  source = v.source;
                }
                // lib.optionalAttrs (v.expires != null) {
                  expires = v.expires;
                }
                // lib.optionalAttrs (v.reason != null) {
                  reason = v.reason;
                }
              ) conf.bannedPlayers;
              "server.properties".value = conf.serverProperties;
              "allowed_symlinks.txt".value = conf.allowedSymlinks;
            }
            // conf.files
          );

          msConfig = managementSystemConfig name conf;

          dataDir = "${cfg.dataDir}/${name}";

          markManaged = file: "echo ${file} >> .nix-minecraft-managed";
          cleanAllManaged = ''
            if [ -e .nix-minecraft-managed ]; then
              readarray -t to_delete < .nix-minecraft-managed
              rm -rf "''${to_delete[@]}"
              rm .nix-minecraft-managed
            fi
          '';

          startPre =
            let
              backup = file: ''
                if [[ -e ${file} ]]; then
                  echo ${file} "already exists, moving"
                  mv ${file} ${file}.bak
                fi
              '';
              mkSymlinks = concatStringsSep "\n" (
                mapAttrsToList (
                  n_: v_:
                  let
                    n = escapeShellArg n_;
                    v = escapeShellArg v_;
                  in
                  ''
                    ${backup n}
                    mkdir -p "$(dirname ${n})"

                    ln -sf ${v} ${n}

                    ${markManaged n}
                  ''
                ) symlinks
              );

              mkFiles = concatStringsSep "\n" (
                mapAttrsToList (
                  n_: v_:
                  let
                    n = escapeShellArg n_;
                    v = escapeShellArg v_;
                  in
                  ''
                    ${backup n}
                    mkdir -p "$(dirname ${n})"

                    if ${pkgs.file}/bin/file --mime-encoding ${v} | grep -v '\bbinary$' -q; then
                      ${pkgs.gawk}/bin/awk '{
                        for(varname in ENVIRON)
                          gsub("@"varname"@", ENVIRON[varname])
                        print
                      }' ${v} > ${n}
                    else
                      cp -r --dereference ${v} -T ${n}
                      chmod +w -R ${n}
                    fi

                    ${markManaged n}
                  ''
                ) files
              );
            in
            ''
              ${cleanAllManaged}
              ${mkSymlinks}
              ${mkFiles}
              ${conf.extraStartPre}
            '';

          stopPost = ''
            ${cleanAllManaged}
            ${conf.extraStopPost}
          '';

          sock = conf.managementSystem.tmux.socketPath name;

          wrapper = pkgs.writeShellApplication {
            name = "minecraft-server-${name}-wrapper";
            text = ''
              set -eo pipefail

              cleanup() {
                # Only try graceful stop if the server is still running.
                # If the script exits via SIGTERM (launchd stop), we need
                # to send the stop command and wait. If the server exited
                # on its own, the session is gone and we just clean up files.
                ${conf.extraStopPre}
                if ${pkgs.tmux}/bin/tmux -S ${escapeShellArg sock} has-session 2>/dev/null; then
                  ${msConfig.stop}
                fi
                ${stopPost}
              }
              trap cleanup EXIT

              # Source environment file so @var@ substitution works in template files
              ${optionalString (cfg.environmentFile != null) ''
                set -a
                source ${escapeShellArg (toString cfg.environmentFile)}
                set +a
              ''}

              ${startPre}

              # Start the server via tmux
              ${msConfig.start}
              ${conf.extraStartPost}

              # Wait for the tmux session to exit (or until SIGTERM arrives)
              while ${pkgs.tmux}/bin/tmux -S ${escapeShellArg sock} has-session 2>/dev/null; do
                sleep 5
              done
            '';
            runtimeInputs = [
              pkgs.coreutils
              pkgs.gnugrep
              pkgs.gawk
              pkgs.file
              pkgs.tmux
            ];
          };
        in
        {
          name = "org.nixos.minecraft-server-${name}";
          value = {
            serviceConfig = {
              KeepAlive =
                if conf.restart == "always" then
                  true
                else if conf.restart == "on-failure" then
                  {
                    SuccessfulExit = false;
                  }
                else if conf.restart == "on-abnormal" then
                  {
                    Crashed = true;
                  }
                else
                  false;
              RunAtLoad = conf.autoStart;
              WorkingDirectory = dataDir;
              UserName = cfg.user;
              GroupName = cfg.group;
              ExitTimeOut = 75;
              StandardOutPath = "${dataDir}/logs/stdout.log";
              StandardErrorPath = "${dataDir}/logs/stderr.log";
              # When launchd terminates the job, prevent it from killing
              # the tmux-managed child processes (Minecraft server JVM).
              AbandonProcessGroup = true;
              # ThrottleInterval: allow restarts at most every 24s,
              # matching systemd's default startLimitIntervalSec=120 / startLimitBurst=5
              ThrottleInterval = 24;
            };
            command = "${getExe wrapper}";
            path = [ pkgs.tmux ] ++ conf.path;
            environment = conf.environment;
          };
        }
      ) servers;
    }
  ]);
}
