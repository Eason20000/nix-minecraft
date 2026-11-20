{
  description = "A single Minecraft server on nix-darwin";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-minecraft = {
      url = "github:Infinidoge/nix-minecraft";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nix-darwin,
      nix-minecraft,
      ...
    }:
    {
      darwinConfigurations."example" = nix-darwin.lib.darwinSystem {
        specialArgs = { inherit nix-minecraft; };
        modules = [
          ./configuration.nix
          {
            nixpkgs.hostPlatform = "aarch64-darwin";
            nixpkgs.overlays = [ nix-minecraft.overlay ];
          }
        ];
      };
    };
}
