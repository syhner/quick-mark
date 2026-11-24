{
  description = "Minimal native macOS app for marking up screenshots";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "aarch64-darwin" "x86_64-darwin" ];
      # Info.plist is the single source of the version.
      version = builtins.head (builtins.match
        ".*<key>CFBundleShortVersionString</key>[[:space:]]*<string>([^<]*)</string>.*"
        (builtins.readFile ./Info.plist));
    in
    {
      packages = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in rec {
          quickmark = pkgs.swiftPackages.stdenv.mkDerivation {
            pname = "quickmark";
            inherit version;
            src = self;
            nativeBuildInputs = [ pkgs.swift pkgs.swiftpm ];
            swiftpmFlags = [ "--product" "QuickMark" ];
            installPhase = ''
              runHook preInstall
              scripts/bundle.sh "$(swiftpmBinPath)/QuickMark" "$out/Applications/QuickMark.app"
              runHook postInstall
            '';
            meta = {
              description = "Minimal native macOS app for marking up screenshots";
              homepage = "https://github.com/syhner/quick-mark";
              license = pkgs.lib.licenses.mit;
              platforms = pkgs.lib.platforms.darwin;
              mainProgram = "QuickMark";
            };
          };
          default = quickmark;
        });

      apps = forAllSystems (system: rec {
        quickmark = {
          type = "app";
          program = "${self.packages.${system}.quickmark}/Applications/QuickMark.app/Contents/MacOS/QuickMark";
        };
        default = quickmark;
      });
    };
}
