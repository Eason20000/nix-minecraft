self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.minecraft-servers;

  inherit (lib)
    all
    attrNames
    attrValues
    concatStringsSep
    elem
    escapeShellArg
    filter
    filterAttrs
    flatten
    getExe
    hasPrefix
    isDerivation
    isStringLike
    mapAttrs'
    mapAttrsToList
    mkAfter
    mkDefault
    mkIf
    mkOption
    nameValuePair
    optional
    optionalString
    types
    ;
  inherit (self.lib) mkOpt';

  servers = filterAttrs (_: conf: conf.enable) cfg.servers;

  environmentFile = if cfg.environmentFile == null then null else toString cfg.environmentFile;

  # Anything that is not in the Nix store is written after activation on
  # darwin (sops templates are rendered in `postActivation` and by a launchd
  # daemon), which is later than the first start of the servers. Wait for
  # these sources instead of failing on a missing file.
  nonStoreSources =
    conf:
    filter (source: !hasPrefix "/nix/store/" source) (
      map toString (attrValues (filterAttrs (_: value: isStringLike value) (conf.files // conf.symlinks)))
      ++ optional (environmentFile != null) environmentFile
    );

  # systemd's `Restart=` has more values than launchd can express. launchd can
  # only restart on an unsuccessful exit, so treat everything but `no` and
  # `always` as `on-failure` (and warn about it).
  restartPolicy =
    conf:
    if conf.restart == "no" then
      "no"
    else if conf.restart == "always" then
      "always"
    else
      "on-failure";

  installDir = dir: ''
    ${pkgs.coreutils}/bin/install -d -m 0750 -o ${toString cfg.userUid} -g ${toString cfg.groupGid} ${escapeShellArg (toString dir)}
  '';

  mkWrapper =
    name: conf:
    let
      service = conf._service;
      statusFile = conf.managementSystem.tmux.exitStatusFile name;
      socketPath = service.environment.STDIN_SOCKET_PATH;
      sources = nonStoreSources conf;
      restart = restartPolicy conf;

      # `services.minecraft-servers.servers.<name>.path` mirrors systemd's
      # `path` option, so it may mix packages and literal directories.
      extraPath = concatStringsSep ":" (
        map (entry: if isDerivation entry then "${toString entry}/bin" else toString entry) service.path
      );

      exportEnvironment = concatStringsSep "\n" (
        mapAttrsToList (var: value: "export ${var}=${escapeShellArg value}") service.environment
      );

      # A natural exit is the one case where launchd needs the exit status:
      # `on-failure` restarts only when the JVM failed, while `always` must
      # also restart after a clean in-game `stop`.
      naturalExit =
        if restart == "no" then
          "exit 0"
        else if restart == "always" then
          ''
            # KeepAlive restarts the job; the exit status itself is unused.
            exit 1
          ''
        else
          ''
            status=1
            if [[ -s ${escapeShellArg statusFile} ]]; then
              status=$(cat ${escapeShellArg statusFile})
            fi
            if [[ ! "$status" =~ ^[0-9]+$ ]]; then
              status=1
            fi

            if [[ "$status" -eq 0 ]]; then
              exit 0
            fi
            exit 1
          '';
    in
    pkgs.writeShellApplication {
      name = "minecraft-server-${name}-launchd";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.findutils
        pkgs.gnugrep
        pkgs.gnused
        pkgs.tmux
        pkgs.bash
      ];
      # The generated script embeds store paths and is checked by shellcheck,
      # which would otherwise complain about quoting and non-constant sources.
      excludeShellChecks = [
        "SC1090"
        "SC1091"
        "SC2016"
        "SC2086"
      ];
      text = ''
        export HOME=${escapeShellArg (toString cfg.dataDir)}
        export LANG=en_US.UTF-8
        ${optionalString (extraPath != "") ''
          export PATH=${escapeShellArg extraPath}:$PATH
        ''}
        ${exportEnvironment}

        ${optionalString (environmentFile != null) ''
          if [[ -f ${escapeShellArg environmentFile} ]]; then
            set -a
            # shellcheck disable=SC1090
            source ${escapeShellArg environmentFile}
            set +a
          fi
        ''}

        ${optionalString (sources != [ ]) ''
          # shellcheck disable=SC2043
          for source in ${concatStringsSep " " (map escapeShellArg sources)}; do
            for _ in {1..120}; do
              if [[ -e "$source" ]]; then
                break
              fi
              sleep 1
            done
            if [[ ! -e "$source" ]]; then
              echo "minecraft-server-${name}: missing $source after 120s" >&2
              exit 1
            fi
          done
        ''}

        tmux=${pkgs.tmux}/bin/tmux
        socket=${escapeShellArg socketPath}
        pidfile=${escapeShellArg "${cfg.dataDir}/${name}/.launchd.pid"}

        # launchctl does not wait for the previous job to exit when it reloads a
        # changed plist, so a new wrapper may start while the old one is still
        # stopping. Wait for it, otherwise both would write the same files.
        if [[ -f "$pidfile" ]]; then
          old_pid=$(cat "$pidfile" 2>/dev/null || true)
          if [[ "$old_pid" =~ ^[0-9]+$ ]] && [[ "$old_pid" != "$$" ]] && kill -0 "$old_pid" 2>/dev/null; then
            echo "minecraft-server-${name}: waiting for previous instance $old_pid" >&2
            for _ in {1..90}; do
              if ! kill -0 "$old_pid" 2>/dev/null; then
                break
              fi
              sleep 1
            done
          fi
        fi

        # A session without a wrapper (SIGKILLed job, crash, machine reboot) is
        # still holding the world and the port: stop it before starting again.
        stop_session() {
          local stop_pid
          if ! "$tmux" -S "$socket" has-session 2>/dev/null; then
            return 0
          fi

          ${service.scripts.stop} &
          stop_pid=$!
          for _ in {1..75}; do
            if ! kill -0 "$stop_pid" 2>/dev/null; then
              break
            fi
            sleep 1
          done
          if kill -0 "$stop_pid" 2>/dev/null; then
            # The stop command did not take effect in time; do not leave the
            # JVM behind as an orphan holding the port.
            "$tmux" -S "$socket" kill-server 2>/dev/null
            wait "$stop_pid"
          fi
        }

        if "$tmux" -S "$socket" has-session 2>/dev/null; then
          echo "minecraft-server-${name}: stopping leftover session" >&2
          stop_session
        fi

        rm -f ${escapeShellArg statusFile}
        echo "$$" > "$pidfile"

        # shellcheck disable=SC2329
        on_term() {
          set +e
          trap - TERM INT

          stop_session
          ${service.scripts.stopPost}
          rm -f "$pidfile"
          exit 0
        }
        trap on_term TERM INT

        ${service.scripts.startPre}

        ${service.scripts.start}
        ${service.scripts.startPost}

        while "$tmux" -S "$socket" has-session 2>/dev/null; do
          sleep 2
        done

        ${service.scripts.stopPost}
        rm -f "$pidfile"

        ${naturalExit}
      '';
    };

  mkDaemon =
    name: conf:
    nameValuePair "minecraft-server-${name}" {
      command = getExe (mkWrapper name conf);
      serviceConfig = {
        UserName = cfg.user;
        GroupName = cfg.group;
        WorkingDirectory = "${cfg.dataDir}/${name}";
        RunAtLoad = conf.autoStart;
        # `SuccessfulExit` implies `RunAtLoad`, so a job that should not start
        # on load cannot use it.
        KeepAlive = if !conf.autoStart || conf.restart == "no" then false else { SuccessfulExit = false; };
        ThrottleInterval = 15;
        ExitTimeOut = 90;
        ProcessType = cfg.processType;
        StandardOutPath = "${cfg.dataDir}/${name}/logs/launchd.out.log";
        StandardErrorPath = "${cfg.dataDir}/${name}/logs/launchd.err.log";
        # 0007, as systemd's UMask for the NixOS module.
        Umask = 7;
        SoftResourceLimits.NumberOfFiles = 65536;
      };
    };
in
{
  imports = [ self.commonModules.minecraft-servers ];

  options.services.minecraft-servers = {
    dataDir = mkOpt' types.path "/var/lib/minecraft" ''
      Directory to store the Minecraft servers.
      Each server will be under a subdirectory named after
      the server name in this directory, such as <literal>/var/lib/minecraft/servername</literal>.
    '';

    user = mkOpt' types.str "_minecraft" ''
      Name of the user the servers run as.

      This should not be an administrator account: the server is not a trusted
      service.
    '';

    group = mkOpt' types.str "_minecraft" ''
      Name of the group the servers run as.
    '';

    createUser = mkOpt' types.bool true ''
      Whether to create <option>services.minecraft-servers.user</option> and
      <option>services.minecraft-servers.group</option>.

      Set this to <literal>false</literal> if the account already exists, for
      example because it was created manually before the first activation (which
      needs Full Disk Access over SSH). In that case
      <option>services.minecraft-servers.userUid</option> and
      <option>services.minecraft-servers.groupGid</option> must match the
      existing account.
    '';

    userUid = mkOpt' types.int 536 ''
      UID of <option>services.minecraft-servers.user</option>.
    '';

    groupGid = mkOpt' types.int 536 ''
      GID of <option>services.minecraft-servers.group</option>.
    '';

    processType =
      mkOpt'
        (types.enum [
          "Background"
          "Standard"
          "Adaptive"
          "Interactive"
        ])
        "Interactive"
        ''
          launchd <literal>ProcessType</literal> for the server jobs.

          launchd applies light CPU and I/O throttling when this is unset, which
          hurts tick times, so the default is <literal>Interactive</literal>.
        '';

    runDir = mkOpt' types.path "${cfg.dataDir}/run" ''
      Deprecated: Directory to place the runtime tmux sockets into.
      Each server's console will be a tmux socket file in the form of <literal>servername.sock</literal>.
      To connect to the console, run `tmux -S ${cfg.dataDir}/run/servername.sock attach`,
      press `Ctrl + b` then `d` to detach.

      Please use <option>services.minecraft-servers.managementSystem.tmux.socketPath</option> instead.
    '';

    servers = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            enableReload = mkOpt' types.bool false ''
              Reload the server when its configuration changes.

              Darwin has no systemd reload, so this has no effect: the job is
              restarted when its configuration changes.
            '';
          };
        }
      );
    };
  };

  config = mkIf cfg.enable {
    # Keep sockets and exit status files inside the data directory. These are
    # set with `mkDefault` so a per-server `managementSystem` can override them.
    services.minecraft-servers.managementSystem.tmux = {
      # Defining `managementSystem` here replaces the shared option's default,
      # so re-state the management system darwin supports.
      enable = mkDefault true;
      socketPath = mkDefault (name: "${cfg.dataDir}/run/${name}.sock");
      exitStatusFile = mkDefault (name: "${cfg.dataDir}/${name}/.last-exit-status");
    };

    assertions = [
      {
        assertion = all (conf: conf.managementSystem.tmux.enable) (attrValues servers);
        message = ''
          Darwin only supports the tmux management system.
          Set `services.minecraft-servers.managementSystem.tmux.enable` to `true`
          (and `systemd-socket.enable` to `false`) for every server.
        '';
      }
      {
        assertion = all (conf: !conf.managementSystem.systemd-socket.enable) (attrValues servers);
        message = ''
          `systemd-socket` is not available on darwin: launchd socket activation
          cannot pass the socket to the JVM. Use `managementSystem.tmux` instead.
        '';
      }
      {
        assertion = all (conf: conf.stopCommand != null) (attrValues servers);
        message = ''
          `stopCommand = null` relies on systemd signalling the main process,
          which the tmux management system cannot do. Set an in-game command
          (`stop` for servers, `end` for proxies).
        '';
      }
      {
        assertion = all (
          name:
          (config.services.minecraft-servers.servers.${name}.managementSystem.tmux.exitStatusFile name)
          != null
        ) (attrNames servers);
        message = ''
          Darwin needs `managementSystem.tmux.exitStatusFile` to tell a clean
          shutdown from a crash; do not set it to `null` there.
        '';
      }
      {
        assertion = cfg.userUid >= 501;
        message = ''
          `services.minecraft-servers.userUid` must be at least 501 so it does
          not collide with macOS system accounts.
        '';
      }
      {
        assertion = cfg.groupGid >= 501;
        message = ''
          `services.minecraft-servers.groupGid` must be at least 501 so it does
          not collide with macOS system groups.
        '';
      }
    ];

    warnings = flatten [
      (mapAttrsToList (
        name: conf:
        optional conf.enableReload ''
          `services.minecraft-servers.servers.${name}.enableReload` has no effect on darwin:
          the job is restarted when its configuration changes.
        ''
      ) servers)
      (mapAttrsToList (
        name: conf:
        optional (!conf.autoStart && conf.restart != "no") ''
          `services.minecraft-servers.servers.${name}` sets `autoStart = false` with
          `restart = "${conf.restart}"`. launchd implies `RunAtLoad` when `KeepAlive`
          is set, so restarting is disabled until the job is started manually.
        ''
      ) servers)
      (mapAttrsToList (
        name: conf:
        optional
          (
            !elem conf.restart [
              "no"
              "on-failure"
              "always"
            ]
          )
          ''
            `services.minecraft-servers.servers.${name}.restart = "${conf.restart}"` is a
            systemd-specific policy; it is treated as `on-failure` on darwin.
          ''
      ) servers)
    ];

    users.users = mkIf cfg.createUser {
      ${cfg.user} = {
        uid = cfg.userUid;
        gid = cfg.groupGid;
        home = cfg.dataDir;
        createHome = false;
        shell = "/usr/bin/false";
        description = "System user for Minecraft servers";
      };
    };

    users.groups = mkIf cfg.createUser {
      ${cfg.group} = {
        gid = cfg.groupGid;
        description = "System group for Minecraft servers";
      };
    };

    users.knownUsers = optional cfg.createUser cfg.user;
    users.knownGroups = optional cfg.createUser cfg.group;

    # Runs as root before groups/users are created, so use numeric ids. The
    # directories must exist before launchd loads the jobs.
    system.activationScripts.extraActivation.text = mkAfter (
      concatStringsSep "\n" (
        map installDir [
          cfg.dataDir
          "${cfg.dataDir}/run"
        ]
        ++ mapAttrsToList (
          name: _:
          concatStringsSep "\n" (
            map installDir [
              "${cfg.dataDir}/${name}"
              "${cfg.dataDir}/${name}/logs"
            ]
          )
        ) servers
      )
    );

    launchd.daemons = mapAttrs' mkDaemon servers;
  };
}
