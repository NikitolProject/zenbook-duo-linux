{

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forEachSystem = nixpkgs.lib.genAttrs systems;
    in
    {
      nixosModules = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = {
            hardware.sensor.iio.enable = true;
            programs.iio-hyprland.enable = true;
            systemd.services.zenbook-duo-linux = {
              enable = true;
              path = with pkgs; [
                bash
                mutter
                usbutils
                inotify-tools
                (python3.withPackages (py-pkgs: with py-pkgs; [ pyusb ]))
              ];
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                ExecStart = "${pkgs.bash}/bin/bash ${./duo.sh}";
                Restart = "always";
                Nice = -10;
              };
            };
          };
        }
      );
    };
}
