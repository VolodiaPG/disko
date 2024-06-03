{
  nixosConfig,
  diskoLib,
  pkgs ? nixosConfig.pkgs,
  hostPkgs ? nixosConfig.config.disko.hostPkgs,
  lib ? pkgs.lib,
  name ? "${nixosConfig.config.networking.hostName}-disko-images",
  extraPostVM ? nixosConfig.config.disko.extraPostVM,
  checked ? false,
}: let
  vmTools = localpkgs:
    localpkgs.vmTools.override {
      rootModules = ["9p" "9pnet_virtio" "virtio_pci" "virtio_blk"] ++ nixosConfig.config.disko.extraRootModules;
      kernel =
        localpkgs.aggregateModules
        (with nixosConfig.config.boot.kernelPackages;
          [kernel]
          ++ lib.optional (lib.elem "zfs" nixosConfig.config.disko.extraRootModules) zfs);
    };
  cleanedConfig = diskoLib.testLib.prepareDiskoConfig nixosConfig.config diskoLib.testLib.devices;
  systemToInstall = nixosConfig.extendModules {
    modules = [
      {
        disko.devices = lib.mkForce cleanedConfig.disko.devices;
        boot.loader.grub.devices = lib.mkForce cleanedConfig.boot.loader.grub.devices;
      }
    ];
  };
  hostDependencies = with hostPkgs; [
    bash
    coreutils
    gnused
    nix
    findutils
  ];

  dependencies = with pkgs;
    [
      bash
      coreutils
      gnused
      parted # for partprobe
      systemdMinimal
      nix
      util-linux
      findutils
      gawk
    ]
    ++ nixosConfig.config.disko.extraDependencies;
  preVM = ''
    ${lib.concatMapStringsSep "\n" (disk: "truncate -s ${disk.imageSize} ${disk.name}.raw") (lib.attrValues nixosConfig.config.disko.devices.disk)}
  '';
  postVM = let
    format =
      if nixosConfig.config.disko.format == "qcow2-compressed"
      then "qcow2"
      else nixosConfig.config.disko.format;
    compress = lib.optionalString (nixosConfig.config.disko.format == "qcow2-compressed") "-c";
    filename =
      "nixos."
      + {
        qcow2 = "qcow2";
        vdi = "vdi";
        vpc = "vhd";
        raw = "img";
      }
      .${format}
      or format;
    dothing = disk: (
      if format == "raw"
      then ''
        mv ${disk.name}.raw "$out/${disk}"
      ''
      else ''
        ${hostPkgs.qemu-utils}/bin/qemu-img convert -f raw -O ${format} ${compress} ${disk.name}.raw "$out/${filename}"
      ''
    );
  in ''
    mkdir -p "$out"
    ${lib.concatMapStringsSep "\n" dothing (lib.attrValues nixosConfig.config.disko.devices.disk)}
    ${extraPostVM}
  '';

  closureInfo = pkgs.closureInfo {
    rootPaths = [systemToInstall.config.system.build.toplevel];
  };
  partitioner = ''
    # running udev, stolen from stage-1.sh
    echo "running udev..."
    ln -sfn /proc/self/fd /dev/fd
    ln -sfn /proc/self/fd/0 /dev/stdin
    ln -sfn /proc/self/fd/1 /dev/stdout
    ln -sfn /proc/self/fd/2 /dev/stderr

    mkdir -p /etc/udev
    ln -sfn ${systemToInstall.config.system.build.etc}/etc/udev/rules.d /etc/udev/rules.d
    mkdir -p /dev/.mdadm
    ${pkgs.systemdMinimal}/lib/systemd/systemd-udevd --daemon
    partprobe
    udevadm trigger --action=add
    udevadm settle

    ${systemToInstall.config.system.build.diskoScript}
    echo "$(uname -a)"
    echo "${closureInfo}"
  '';

  installer = ''
    # populate nix db, so nixos-install doesn't complain
    # Provide a Nix database so that nixos-install can copy closures.

    mkdir -p /mnt/nix/store
    mount --bind /nix/store /mnt/nix/store

    mkdir -p "${systemToInstall.config.disko.rootMountPoint}/nix/var/nix"
    mkdir -p "${systemToInstall.config.disko.rootMountPoint}/nix/var/nix/daemon-socket"
    export NIX_STATE_DIR=${systemToInstall.config.disko.rootMountPoint}/nix/var/nix
    nix --extra-experimental-features nix-command daemon&
    DAEMON=$?
    echo $DAEMON

    echo $(cat /proc/meminfo)
    nix-store --load-db < "${closureInfo}/registration"
    echo "loaded db"


    # We copy files with cp because `nix copy` seems to have a large memory leak
    #mkdir -p ${systemToInstall.config.disko.rootMountPoint}/nix/store
    #xargs cp --recursive --target ${systemToInstall.config.disko.rootMountPoint}/nix/store < ${closureInfo}/store-paths
    #TOTO=$(mktemp -d)
    #xargs -I{} mount -o rw,x-mount.mkdir {} $TOTO < ${closureInfo}/store-paths
    #${pkgs.fpart}/bin/fpsync -n $(nprocs) $TOTO ${systemToInstall.config.disko.rootMountPoint}/nix/store


    ${systemToInstall.config.system.build.nixos-install}/bin/nixos-install --root ${systemToInstall.config.disko.rootMountPoint} --system ${systemToInstall.config.system.build.toplevel} --keep-going --no-channel-copy -v --no-root-password --option binary-caches ""
    umount -Rv ${systemToInstall.config.disko.rootMountPoint}
    kill $DAEMON
  '';
  #-net socket,fd=3,listen:/nix/var/nix/daemon-socket/socket
  QEMU_OPTS = "-drive if=pflash,format=raw,unit=0,readonly=on,file=${pkgs.OVMF.firmware}" + " " + (lib.concatMapStringsSep " " (disk: "-drive file=${disk.name}.raw,if=virtio,cache=unsafe,werror=report,format=raw") (lib.attrValues nixosConfig.config.disko.devices.disk));

  runInLinuxVMNoKVM = drv:
    lib.overrideDerivation ((vmTools pkgs).runInLinuxVM drv) (old: {
      requiredSystemFeatures = lib.remove "kvm" old.requiredSystemFeatures;
      builder = "${hostPkgs.bash}/bin/bash";
      args = ["-e" ((vmTools hostPkgs).vmRunCommand modifiedQemuCommandLinux)];
    });

  qemu-common = (vmTools pkgs).qemu-common;
  qemu = hostPkgs.qemu_kvm;
  modifiedQemu = "${qemu-common.qemuBinary qemu} \\";
  modifiedQemuCommandLinux = builtins.replaceStrings [(builtins.head (builtins.elemAt (builtins.split "^(.+)\n  -nographic" (vmTools pkgs).qemuCommandLinux) 1))] [modifiedQemu] (vmTools pkgs).qemuCommandLinux;
in {
  pure = runInLinuxVMNoKVM (pkgs.runCommand name
    {
      buildInputs = dependencies;
      inherit preVM postVM QEMU_OPTS;
      memSize = nixosConfig.config.disko.memSize;
    }
    (partitioner + installer));
  impure =
    diskoLib.writeCheckedBash {
      inherit checked;
      pkgs = pkgs;
    }
    name ''
      set -efu
      export PATH=${hostPkgs.lib.makeBinPath hostDependencies}
      showUsage() {
      cat <<\USAGE
      Usage: $script [options]

      Options:
      * --pre-format-files <src> <dst>
        copies the src to the dst on the VM, before disko is run
        This is useful to provide secrets like LUKS keys, or other files you need for formating
      * --post-format-files <src> <dst>
        copies the src to the dst on the finished image
        These end up in the images later and is useful if you want to add some extra stateful files
        They will have the same permissions but will be owned by root:root
      * --build-memory <amt>
        specify the ammount of memory that gets allocated to the build vm (in mb)
        This can be usefull if you want to build images with a more involed NixOS config
        By default the vm will get 1024M/1GB
      USAGE
      }

      export out=$PWD
      TMPDIR=$(mktemp -d); export TMPDIR
      mkdir -p $TMPDIR/nix/var/nix/daemon-socket/socket
      ln -sfn /nix/var/nix/daemon-socket/socket $TMPDIR/nix/var/nix/daemon-socket/socket
      trap 'rm -rf "$TMPDIR"' EXIT
      cd "$TMPDIR"

      mkdir copy_before_disko copy_after_disko

      while [[ $# -gt 0 ]]; do
        case "$1" in
        --pre-format-files)
          src=$2
          dst=$3
          cp --reflink=auto -r "$src" copy_before_disko/"$(echo "$dst" | base64)"
          shift 2
          ;;
        --post-format-files)
          src=$2
          dst=$3
          cp --reflink=auto -r "$src" copy_after_disko/"$(echo "$dst" | base64)"
          shift 2
          ;;
        --build-memory)
          regex="^[0-9]+$"
          if ! [[ $2 =~ $regex ]]; then
            echo "'$2' is not a number"
            exit 1
          fi
          build_memory=$2
          shift 1
          ;;
        *)
          showUsage
          exit 1
          ;;
        esac
        shift
      done

      export preVM=${diskoLib.writeCheckedBash {
          inherit checked;
          pkgs = hostPkgs;
        } "preVM.sh" ''
          set -efu
          mv copy_before_disko copy_after_disko xchg/
          ${preVM}
        ''}
      export postVM=${diskoLib.writeCheckedBash {
          inherit checked;
          pkgs = hostPkgs;
        } "postVM.sh"
        postVM}
      export origBuilder=${hostPkgs.writeScript "disko-builder" ''
        set -eu
        export PATH=${pkgs.lib.makeBinPath dependencies}
        for src in /tmp/xchg/copy_before_disko/*; do
          [ -e "$src" ] || continue
          dst=$(basename "$src" | base64 -d)
          mkdir -p "$(dirname "$dst")"
          cp -r "$src" "$dst"
        done
        set -f
        ${partitioner}
        set +f
        for src in /tmp/xchg/copy_after_disko/*; do
          [ -e "$src" ] || continue
          dst=/mnt/$(basename "$src" | base64 -d)
          mkdir -p "$(dirname "$dst")"
          cp -r "$src" "$dst"
        done
        ${installer}
      ''}

      build_memory=''${build_memory:-${builtins.toString nixosConfig.config.disko.memSize}}
      QEMU_OPTS=${lib.escapeShellArg QEMU_OPTS}
      QEMU_OPTS+=" -m $build_memory"
      export QEMU_OPTS
      ${hostPkgs.bash}/bin/sh -e ${(vmTools hostPkgs).vmRunCommand modifiedQemuCommandLinux}
      cd /
    '';
}
