{
  nix-minecraft,
  pkgs,
  ...
}:

{
  imports = [ nix-minecraft.darwinModules.minecraft-servers ];

  # The Mojang server jars are unfree.
  nixpkgs.config.allowUnfree = true;

  services.minecraft-servers = {
    enable = true;
    eula = true;

    servers.survival = {
      enable = true;
      jvmOpts = "-Xmx4G -Xms2G";

      package = pkgs.vanilla-server;

      serverProperties = {
        server-port = 25565;
        motd = "nix-darwin Minecraft";
      };
    };
  };

  # nix-darwin needs this for options that used to apply to the user running
  # `darwin-rebuild`. It must name an existing macOS account; the Minecraft
  # servers themselves run as `_minecraft`, which the module creates.
  system.primaryUser = "alice";
  system.stateVersion = 6;

  # The first activation that creates `_minecraft` needs Full Disk Access when
  # `darwin-rebuild` runs over SSH: System Settings -> General -> Sharing ->
  # Remote Login -> "Allow full disk access for remote users". Alternatively,
  # run `darwin-rebuild switch` once from a graphical session.
}
