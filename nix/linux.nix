{
  lib,
  stdenvNoCC,
  stdenv,
  fetchurl,
  buildFHSEnv,
  bintools,
  xz,
  asar,
  typescript,

  # Runtime dependencies provided inside the FHS environment
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  fontconfig,
  freetype,
  gcc-unwrapped,
  gdk-pixbuf,
  glib,
  gsettings-desktop-schemas,
  gtk3,
  libdrm,
  libglvnd,
  libnotify,
  libX11,
  libxcb,
  libXcomposite,
  libXdamage,
  libXext,
  libXfixes,
  libxkbcommon,
  libXrandr,
  libxshmfence,
  libgbm,
  nspr,
  nss,
  pango,
  pipewire,
  vulkan-loader,
  wayland,
  systemd,
  libpulseaudio,
  version,
}:

let
  pname = "sidra";

  # The nix-hash CI job updates each URL and hash as one pair from each release.
  # Do not edit these values by hand, because each pair must stay in sync.
  sources = {
    x86_64-linux = {
      url = "https://github.com/wimpysworld/sidra/releases/download/${version}/Sidra-${version}-linux-amd64.deb";
      hash = "sha256-nANUulzCujNhig4MFWGvTXv5U3dw6mXPYuK7OQWpiV4=";
    };
    aarch64-linux = {
      url = "https://github.com/wimpysworld/sidra/releases/download/${version}/Sidra-${version}-linux-arm64.deb";
      hash = "sha256-2OTAyvdYrsk2jx8m+LGiMif783vjrHCgKk153t4CLLw=";
    };
  };

  src = fetchurl sources.${stdenv.hostPlatform.system};

  # Type checking needs the full npm tree, including the CastLabs Electron git
  # dependency, so this build only emits. Run the type check and tests before pushing.
  app = stdenvNoCC.mkDerivation {
    pname = "${pname}-app";
    inherit version;

    src = lib.fileset.toSource {
      root = ../.;
      fileset = lib.fileset.unions [
        ../assets
        ../src
        ../tsconfig.json
      ];
    };

    nativeBuildInputs = [ typescript ];

    buildPhase = ''
      runHook preBuild
      tsc -p tsconfig.json --noCheck
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -a dist assets $out/
      rm -rf $out/assets/source
      runHook postInstall
    '';
  };

  asarUnpack = (lib.importJSON ../package.json).build.asarUnpack;

  # Unpack the deb without patching the CastLabs Electron binary, which is
  # VMP-signed for Widevine DRM, and rebuild only app.asar from this tree. The
  # release keeps its node_modules, package.json and Last.fm credentials.
  unpacked = stdenvNoCC.mkDerivation {
    pname = "${pname}-unpacked";
    inherit version src;

    nativeBuildInputs = [
      asar
      bintools # ar
      xz
    ];

    dontConfigure = true;
    dontBuild = true;
    dontFixup = true;

    unpackPhase = ''
      runHook preUnpack
      ${lib.getExe' bintools "ar"} x $src
      tar xf data.tar.xz
      runHook postUnpack
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out
      cp -a opt/Sidra $out/opt
      cp -a usr/share $out/share

      resources=$out/opt/resources
      asar extract $resources/app.asar app
      cp app/assets/lastfm-credentials.json lastfm-credentials.json
      rm -rf app/dist app/assets $resources/app.asar $resources/app.asar.unpacked
      cp -a ${app}/dist ${app}/assets app/
      chmod -R u+w app
      cp lastfm-credentials.json app/assets/lastfm-credentials.json
      # asar matches the unpack glob against absolute paths.
      asar pack "$PWD/app" $resources/app.asar \
        --unpack "{${lib.concatMapStringsSep "," (p: "$PWD/app/${p}") asarUnpack}}"

      # Fix the desktop file to point at the wrapper (will be set by FHS env)
      substituteInPlace $out/share/applications/sidra.desktop \
        --replace-fail /opt/Sidra/sidra sidra

      runHook postInstall
    '';
  };

  # Libraries that the Electron binary links against at runtime
  libs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    fontconfig
    freetype
    gcc-unwrapped.lib
    gdk-pixbuf
    glib
    gsettings-desktop-schemas
    gtk3
    libdrm
    libglvnd
    libnotify
    libX11
    libxcb
    libXcomposite
    libXdamage
    libXext
    libXfixes
    libxkbcommon
    libXrandr
    libxshmfence
    libgbm
    nspr
    nss
    pango
    pipewire
    vulkan-loader
    wayland
    systemd
    libpulseaudio
  ];

  fhs = buildFHSEnv {
    inherit pname version;
    targetPkgs = _: libs;

    runScript = "${unpacked}/opt/sidra";

    extraInstallCommands = ''
      # Desktop file and icons from the deb
      mkdir -p $out/share
      cp -a ${unpacked}/share/applications $out/share/
      cp -a ${unpacked}/share/icons $out/share/

      # Point desktop file Exec at the FHS wrapper
      substituteInPlace $out/share/applications/sidra.desktop \
        --replace-fail "Exec=sidra" "Exec=$out/bin/sidra"
    '';

    meta = {
      description = "An elegant Apple Music desktop client";
      homepage = "https://github.com/wimpysworld/sidra";
      license = lib.licenses.blueOak100;
      maintainers = with lib.maintainers; [ flexiondotorg ];
      platforms = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      sourceProvenance = with lib.sourceTypes; [
        binaryNativeCode
        fromSource
      ];
      mainProgram = "sidra";
    };
  };
in
fhs
