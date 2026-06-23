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
        serviceConfig = {
          Type = "forking";
          GuessMainPID = true;
        };
        hooks = {
          start = ''
            ${tmux} -S ${sock} new -d ${getExe server.package} ${server.jvmOpts}

            # HACK: PrivateUsers makes every user besides root/minecraft `nobody`, so this restores old tmux behavior
            # See https://github.com/Infinidoge/nix-minecraft/issues/5
            ${tmux} -S ${sock} server-access -aw nobody
          '';
          postStart = ''
            ${pkgs.coreutils}/bin/chmod 660 ${sock}
          '';
          stop = ''
            function server_running {
              ${tmux} -S ${sock} has-session
            }

            if ! server_running ; then
              exit 0
            fi

            ${tmux} -S ${sock} send-keys C-u ${escapeShellArg server.stopCommand} Enter

            while server_running; do sleep 1s; done
          '';
        };
      }
    else if ms.systemd-socket.enable then
      {
        serviceConfig = {
          Type = "simple";
          StandardInput = "socket";
          StandardOutput = "journal";
          StandardError = "journal";
        };
        hooks = {
          start = ''
            ${getExe server.package} ${server.jvmOpts}
          '';
          postStart = "";
          stop = ''
            ${optionalString (server.stopCommand != null) ''
              echo ${escapeShellArg server.stopCommand} > ${escapeShellArg (ms.systemd-socket.stdinSocket.path name)}

              while kill -0 "$1" 2> /dev/null; do sleep 1s; done
            ''}
          '';
        };
      }
    else
      builtins.throw "At least one server management system must be enabled.";

  servers = filterAttrs (_: cfg: cfg.enable) cfg.servers;
in
{
  imports = [ ./common.nix ];

  config = mkIf cfg.enable {
    users.users.minecraft = mkIf (cfg.user == "minecraft") {
      group = "minecraft";
      homeMode = "770";
      isSystemUser = true;
    };

    users.groups.minecraft = mkIf (cfg.group == "minecraft") { };

    networking.firewall =
      let
        toOpen = filterAttrs (_: cfg: cfg.openFirewall) servers;
        getTCPPorts =
          n: c:
          [ c.serverProperties.server-port or 25565 ]
          ++ (optional (c.serverProperties.enable-rcon or false) (c.serverProperties."rcon.port" or 25575));
        getUDPPorts =
          n: c:
          optional (c.serverProperties.enable-query or false) (c.serverProperties."query.port" or 25565);
      in
      {
        allowedUDPPorts = flatten (mapAttrsToList getUDPPorts toOpen);
        allowedTCPPorts = flatten (mapAttrsToList getTCPPorts toOpen);
      };

    systemd.tmpfiles.rules = mapAttrsToList (
      name: _: "d '${cfg.dataDir}/${name}' 0770 ${cfg.user} ${cfg.group} - -"
    ) servers;

    systemd.sockets = pipe servers [
      (filterAttrs (name: server: server.managementSystem.systemd-socket.enable))
      (mapAttrs' (
        name: server: {
          name = "minecraft-server-${name}";
          value = {
            requires = [ "minecraft-server-${name}.service" ];
            partOf = [ "minecraft-server-${name}.service" ];
            socketConfig =
              let
                socketConf = server.managementSystem.systemd-socket.stdinSocket;
              in
              {
                ListenFIFO = socketConf.path name;
                SocketMode = socketConf.mode;
                SocketUser = cfg.user;
                SocketGroup = cfg.group;
                RemoveOnStop = true;
                FlushPending = true;
              };
          };
        }
      ))
    ];

    systemd.services = mapAttrs' (
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

        markManaged = file: "echo ${file} >> .nix-minecraft-managed";
        cleanAllManaged = ''
          if [ -e .nix-minecraft-managed ]; then
            readarray -t to_delete < .nix-minecraft-managed
            rm -rf "''${to_delete[@]}"
            rm .nix-minecraft-managed
          fi
        '';

        ExecStartPre =
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

                  # If it's not a binary, substitute env vars. Else, copy it normally
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
          getExe (
            pkgs.writeShellApplication {
              name = "minecraft-server-${name}-start-pre";

              excludeShellChecks = [ "SC2016" ];

              text = ''
                ${cleanAllManaged}
                ${mkSymlinks}
                ${mkFiles}
                ${conf.extraStartPre}
              '';
            }
          );

        ExecStart = getExe (
          pkgs.writeShellApplication {
            name = "minecraft-server-${name}-start";
            text = ''
              ${msConfig.hooks.start}
            '';
          }
        );

        ExecStartPost = getExe (
          pkgs.writeShellApplication {
            name = "minecraft-server-${name}-start-post";
            text = ''
              ${msConfig.hooks.postStart}
              ${conf.extraStartPost}
            '';
          }
        );

        execStopScript = getExe (
          pkgs.writeShellApplication {
            name = "minecraft-server-${name}-stop";
            text = ''
              # systemd has no ExecStopPre hook, so we just run it here.
              ${conf.extraStopPre}

              ${msConfig.hooks.stop}
            '';
          }
        );

        ExecStopPost = getExe (
          pkgs.writeShellApplication {
            name = "minecraft-server-${name}-stop-post";
            text = ''
              ${cleanAllManaged}
              ${conf.extraStopPost}
            '';
          }
        );

        ExecReload = getExe (
          pkgs.writeShellApplication {
            name = "minecraft-server-${name}-reload";
            text = ''
              ${ExecStopPost}
              ${ExecStartPre}
              ${conf.extraReload}
            '';
          }
        );
      in
      {
        name = "minecraft-server-${name}";
        value = {
          description = "Minecraft Server ${name}";
          wantedBy = mkIf conf.autoStart [ "multi-user.target" ];
          requires = optional conf.managementSystem.systemd-socket.enable "minecraft-server-${name}.socket";
          partOf = optional conf.managementSystem.systemd-socket.enable "minecraft-server-${name}.socket";
          after = [
            "network.target"
          ]
          ++ optional conf.managementSystem.systemd-socket.enable "minecraft-server-${name}.socket";

          enable = conf.enable;

          startLimitIntervalSec = 120;
          startLimitBurst = 5;

          serviceConfig = {
            inherit
              ExecStartPre
              ExecStart
              ExecStartPost
              ExecStopPost
              ExecReload
              ;
            ExecStop = "${execStopScript} $MAINPID";

            # the Minecraft server (as of 1.20.6) has a 60s timeout for saving each world.
            # let's let it handle potential lock-ups by itself before resorting to killing it.
            TimeoutStopSec = "1min 15s";

            Restart = conf.restart;
            WorkingDirectory = "${cfg.dataDir}/${name}";
            User = cfg.user;
            Group = cfg.group;
            EnvironmentFile = mkIf (cfg.environmentFile != null) (toString cfg.environmentFile);

            # Default directory for management sockets
            RuntimeDirectory = "minecraft";
            RuntimeDirectoryPreserve = "yes";

            # Hardening
            CapabilityBoundingSet = [ "" ];
            DeviceAllow = [ "" ];
            LockPersonality = true;
            PrivateDevices = true;
            PrivateTmp = true;
            PrivateUsers = true;
            ProtectClock = true;
            ProtectControlGroups = true;
            ProtectHome = true;
            ProtectHostname = true;
            ProtectKernelLogs = true;
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            ProtectProc = "invisible";
            RestrictAddressFamilies = [
              "AF_UNIX"
              "AF_INET"
              "AF_INET6"
            ];
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            SystemCallArchitectures = "native";
            UMask = "0007";
          }
          // msConfig.serviceConfig;

          restartIfChanged = !conf.enableReload;
          reloadIfChanged = conf.enableReload;

          inherit (conf) path environment;
        };
      }
    ) servers;
  };
}
