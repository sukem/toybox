#!/bin/bash

# ------------------------------ Part 1: Setup -------------------------------

# Clear environment variables by restarting script w/bare minimum passed through
[ -z "$NOCLEAR" ] && exec env -i NOCLEAR=1 HOME="$HOME" PATH="$PATH" \
    LINUX="$LINUX" CROSS="$CROSS" CROSS_COMPILE="$CROSS_COMPILE" "$0" "$@"

! [ -d mkroot ] && echo "Run mkroot/mkroot.sh from toybox source dir." && exit 1

# assign command line NAME=VALUE args to env vars, the rest are packages
for i in "$@"; do
  [ "${i/=/}" != "$i" ] && export "$i" || { [ "$i" != -- ] && PKG="$PKG $i"; }
done

# Set default directory locations (overrideable from command line)
: ${TOP:=$PWD/root} ${BUILD:=$TOP/build} ${LOG:=$BUILD/log}
: ${AIRLOCK:=$BUILD/airlock} ${CCC:=$PWD/ccc} ${PKGDIR:=$PWD/mkroot/packages}

announce() { printf "\033]2;$CROSS $*\007" >/dev/tty; printf "\n=== $*\n";}
die() { echo "$@" >&2; exit 1; }

# ----- Are we cross compiling (via CROSS_COMPILE= or CROSS=)

if [ -n "$CROSS_COMPILE" ]; then
  # airlock needs absolute path
  [ -z "${X:=$(command -v "$CROSS_COMPILE"cc)}" ] && die "no ${CROSS_COMPILE}cc"
  CROSS_COMPILE="$(realpath -s "${X%cc}")"
  [ -z "$CROSS" ] && CROSS=${CROSS_COMPILE/*\//} CROSS=${CROSS/-*/}

elif [ -n "$CROSS" ]; then # CROSS=all/allnonstop/$ARCH else list known $ARCHes
  [ ! -d "$CCC" ] && die "No ccc symlink to compiler directory."
  TARGETS="$(ls "$CCC" | sed -n 's/-.*//p' | sort -u)"

  if [ "${CROSS::3}" == all ]; then # loop calling ourselves for each target
    for i in $TARGETS; do
      "$0" "$@" CROSS=$i || [ "$CROSS" == allnonstop ] || exit 1
    done; exit

  else # Find matching cross compiler under ccc/ else list available targets
    CROSS_COMPILE="$(echo "$CCC/$CROSS"-*cross/bin/"$CROSS"*-cc)" # wildcard
    [ ! -e "$CROSS_COMPILE" ] && echo $TARGETS && exit # list available targets
    CROSS_COMPILE="${CROSS_COMPILE%cc}" # trim to prefix for cc/ld/as/nm/strip
  fi
fi

# Set per-target output directory (using "host" if not cross-compiling)
: ${CROSS:=host} ${OUTPUT:=$TOP/$CROSS} ${OUTDOC:=$OUTPUT/docs}

# Verify selected compiler works
${CROSS_COMPILE}cc --static -xc - -o /dev/null <<< "int main(void){return 0;}"||
  die "${CROSS_COMPILE}cc can't create static binaries"

# ----- Create hermetic build environment

if [ -z "$NOAIRLOCK"] && [ -n "$CROSS_COMPILE" ]; then
  # When cross compiling set host $PATH to binaries with known behavior by
  # - building a host toybox later builds use as their command line
  # - cherry-picking specific commands from old path via symlink
  if [ ! -e "$AIRLOCK/toybox" ]; then
    announce "airlock" &&
    PREFIX="$AIRLOCK" KCONFIG_CONFIG=.singleconfig_airlock CROSS_COMPILE= \
      make clean defconfig toybox install_airlock && # see scripts/install.sh
    rm .singleconfig_airlock || exit 1
  fi
  export PATH="$AIRLOCK"
fi

# Create per-target work directories
TEMP="$BUILD/${CROSS}-tmp" && rm -rf "$TEMP" &&
mkdir -p "$TEMP" "$OUTPUT" "$LOG" || exit 1
[ -z "$ROOT" ] && ROOT="$OUTPUT/fs" && rm -rf "$ROOT"
LOG="$LOG/$CROSS"

# ----- log build output

# Install command line recording wrapper, logs all commands run from $PATH
if [ -z "$NOLOGPATH" ]; then
  # Move cross compiler into $PATH so calls to it get logged
  [ -n "$CROSS_COMPILE" ] && PATH="${CROSS_COMPILE%/*}:$PATH" &&
    CROSS_COMPILE=${CROSS_COMPILE##*/}
  export WRAPDIR="$BUILD/record-commands" LOGPATH="$LOG"-commands.txt
  rm -rf "$WRAPDIR" "$LOGPATH" generated/obj &&
  WRAPDIR="$WRAPDIR" CROSS_COMPILE= NOSTRIP=1 source mkroot/record-commands ||
    exit 1
fi

# Start logging stdout/stderr
rm -f "$LOG".{n,y} || exit 1
[ -z "$NOLOG" ] && exec > >(tee "$LOG".n) 2>&1
echo "Building for $CROSS"

# ---------------------- Part 2: Create root filesystem -----------------------

# ----- Create new root filesystem's directory layout.

# FHS wants boot media opt srv usr/{local,share}, stuff under /var...
mkdir -p "$ROOT"/{dev,etc/rc,home,mnt,proc,root,sys,tmp/run,usr/{bin,sbin,lib},var} &&
chmod a+rwxt "$ROOT"/tmp && ln -s usr/{bin,sbin,lib} tmp/run "$ROOT" || exit 1

# Write init script. Runs as pid 1 from initramfs to set up and hand off system.
cat > "$ROOT"/init << 'EOF' &&
#!/bin/sh

export HOME=/home PATH=/bin:/sbin

if ! mountpoint -q dev; then
  mount -t devtmpfs dev dev
  [ $$ -eq 1 ] && ! 2>/dev/null <0 && exec 0<>/dev/console 1>&0 2>&1
  for i in ,fd /0,stdin /1,stdout /2,stderr
  do ln -sf /proc/self/fd${i/,*/} dev/${i/*,/}; done
  mkdir -p dev/shm
  chmod +t /dev/shm
fi
mountpoint -q dev/pts || { mkdir -p dev/pts && mount -t devpts dev/pts dev/pts;}
mountpoint -q proc || mount -t proc proc proc
mountpoint -q sys || mount -t sysfs sys sys
echo 0 99999 > /proc/sys/net/ipv4/ping_group_range

if [ $$ -eq 1 ]; then
  mountpoint -q mnt || [ -e /dev/?da ] && mount /dev/?da /mnt

  # Setup networking for QEMU (needs /proc)
  ifconfig lo 127.0.0.1
  ifconfig eth0 10.0.2.15
  route add default gw 10.0.2.2
  [ "$(date +%s)" -lt 1000 ] && timeout 2 sntp -sq 10.0.2.2 # Ask host
  [ "$(date +%s)" -lt 10000000 ] && sntp -sq time.google.com

  # Run package scripts (if any)
  for i in $(ls -1 /etc/rc 2>/dev/null | sort); do . /etc/rc/"$i"; done
  echo 3 > /proc/sys/kernel/printk

  [ -z "$HANDOFF" ] && [ -e /mnt/init ] && HANDOFF=/mnt/init
  [ -z "$HANDOFF" ] && HANDOFF=/bin/sh && echo -e '\e[?7hType exit when done.'

  exec <>/dev/$(sed '$s@.*/@@' /sys/class/tty/console/active) 2>&1 &&
  $HANDOFF &&
  reboot -f &
  sleep 5
else # for chroot
  /bin/sh
  umount /dev/pts /dev /sys /proc
fi
EOF
chmod +x "$ROOT"/init &&

# Google's nameserver, passwd+group with special (root/nobody) accounts + guest
echo "nameserver 8.8.8.8" > "$ROOT"/etc/resolv.conf &&
cat > "$ROOT"/etc/passwd << 'EOF' &&
root:x:0:0:root:/root:/bin/sh
guest:x:500:500:guest:/home/guest:/bin/sh
nobody:x:65534:65534:nobody:/proc/self:/dev/null
EOF
echo -e 'root:x:0:\nguest:x:500:\nnobody:x:65534:' > "$ROOT"/etc/group || exit 1

# Build any packages listed on command line
for i in ${PKG:+plumbing $PKG}; do
  pushd .
  announce "$i"; PATH="$PKGDIR:$PATH" source $i || die $i
  popd
done

# Build static toybox with existing .config if there is one, else defconfig+sh
if [ -z "$NOTOYBOX" ]; then
  announce toybox
  [ -n "$PENDING" ] && rm -f .config
  grep -q CONFIG_SH=y .config 2>/dev/null && CONF=silentoldconfig || unset CONF
  for i in $PENDING sh route; do XX="$XX"$'\n'CONFIG_${i^^?}=y; done
  [ -e "$ROOT"/lib/libc.so ] || export LDFLAGS=--static
  PREFIX="$ROOT" make clean \
    ${CONF:-defconfig KCONFIG_ALLCONFIG=<(echo "$XX")} toybox install || exit 1
  unset LDFLAGS
fi

# ------------------ Part 3: Build + package bootable system ------------------

# Convert comma separated values in $1 to CONFIG=$2 lines
csv2cfg() { sed -E '/^$/d;s/([^,]*)($|,)/CONFIG_\1\n/g' <<< "$1" | sed '/^$/!{/=/!s/.*/&='"$2/}";}

# ----- Build kernel for target

if [ -z "$LINUX" ] || [ ! -d "$LINUX/kernel" ]; then
  echo 'No $LINUX directory, kernel build skipped.'
else
  # Which architecture are we building a kernel for?
  LINUX="$(realpath "$LINUX")"
  [ "$CROSS" == host ] && CROSS="$(uname -m)"

  # Target-specific info in an (alphabetical order) if/else staircase
  # Each target needs board config, serial console, RTC, ethernet, block device.

  if [ "$CROSS" == armv5l ]; then
    # This could use the same VIRT board as armv7, but let's demonstrate a
    # different one requiring a separate device tree binary.
    QEMU="arm -M versatilepb -net nic,model=rtl8139 -net user"
    KARCH=arm KARGS=ttyAMA0 VMLINUX=arch/arm/boot/zImage
    KCONF=CPU_ARM926T,MMU,VFP,ARM_THUMB,AEABI,ARCH_VERSATILE,ATAGS,DEPRECATED_PARAM_STRUCT,ARM_ATAG_DTB_COMPAT,ARM_ATAG_DTB_COMPAT_CMDLINE_EXTEND,SERIAL_AMBA_PL011,SERIAL_AMBA_PL011_CONSOLE,RTC_CLASS,RTC_DRV_PL031,RTC_HCTOSYS,PCI,PCI_VERSATILE,BLK_DEV_SD,SCSI,SCSI_LOWLEVEL,SCSI_SYM53C8XX_2,SCSI_SYM53C8XX_MMIO,NET_VENDOR_REALTEK,8139CP,SCSI_SYM53C8XX_DMA_ADDRESSING_MODE=0
    DTB=arch/arm/boot/dts/versatile-pb.dtb
  elif [ "$CROSS" == armv7l ] || [ "$CROSS" == aarch64 ]; then
    if [ "$CROSS" == aarch64 ]; then
      QEMU="aarch64 -M virt -cpu cortex-a57"
      KARCH=arm64 VMLINUX=arch/arm64/boot/Image
    else
      QEMU="arm -M virt" KARCH=arm VMLINUX=arch/arm/boot/zImage
    fi
    KARGS=ttyAMA0
    KCONF=MMU,ARCH_MULTI_V7,ARCH_VIRT,SOC_DRA7XX,ARCH_OMAP2PLUS_TYPICAL,ARCH_ALPINE,ARM_THUMB,VDSO,CPU_IDLE,ARM_CPUIDLE,KERNEL_MODE_NEON,SERIAL_AMBA_PL011,SERIAL_AMBA_PL011_CONSOLE,RTC_CLASS,RTC_HCTOSYS,RTC_DRV_PL031,VIRTIO_MENU,VIRTIO_NET,PCI,PCI_HOST_GENERIC,VIRTIO_BLK,VIRTIO_PCI,VIRTIO_MMIO,ATA,ATA_SFF,ATA_BMDMA,ATA_PIIX,PATA_PLATFORM,PATA_OF_PLATFORM,ATA_GENERIC,ARM_LPAE
  elif [ "$CROSS" == hexagon ]; then
    QEMU="hexagon -M comet" KARGS=ttyS0 VMLINUX=vmlinux
    KARCH="hexagon LLVM_IAS=1" KCONF=SPI,SPI_BITBANG,IOMMU_SUPPORT
  elif [ "$CROSS" == i486 ] || [ "$CROSS" == i686 ] ||
       [ "$CROSS" == x86_64 ] || [ "$CROSS" == x32 ]; then
    if [ "$CROSS" == i486 ]; then
      QEMU="i386 -cpu 486 -global fw_cfg.dma_enabled=false" KCONF=M486
    elif [ "$CROSS" == i686 ]; then
      QEMU="i386 -cpu pentium3" KCONF=MPENTIUMII
    else
      QEMU=x86_64 KCONF=64BIT
      [ "$CROSS" == x32 ] && KCONF=X86_X32
    fi
    KARCH=x86 KARGS=ttyS0 VMLINUX=arch/x86/boot/bzImage
    KCONF=$KCONF,UNWINDER_FRAME_POINTER,PCI,BLK_DEV_SD,ATA,ATA_SFF,ATA_BMDMA,ATA_PIIX,NET_VENDOR_INTEL,E1000,SERIAL_8250,SERIAL_8250_CONSOLE,RTC_CLASS
  elif [ "$CROSS" == m68k ]; then
    QEMU="m68k -M q800" KARCH=m68k KARGS=ttyS0 VMLINUX=vmlinux
    KCONF=MMU,M68040,M68KFPU_EMU,MAC,SCSI,SCSI_LOWLEVEL,BLK_DEV_SD,SCSI_MAC_ESP,MACINTOSH_DRIVERS,NET_VENDOR_NATSEMI,MACSONIC,SERIAL_PMACZILOG,SERIAL_PMACZILOG_TTYS,SERIAL_PMACZILOG_CONSOLE
  elif [ "$CROSS" == mips ] || [ "$CROSS" == mipsel ]; then
    QEMU="mips -M malta" KARCH=mips KARGS=ttyS0 VMLINUX=vmlinux
    KCONF=MIPS_MALTA,CPU_MIPS32_R2,SERIAL_8250,SERIAL_8250_CONSOLE,PCI,BLK_DEV_SD,ATA,ATA_SFF,ATA_BMDMA,ATA_PIIX,NET_VENDOR_AMD,PCNET32,POWER_RESET,POWER_RESET_SYSCON
    [ "$CROSS" == mipsel ] && KCONF=$KCONF,CPU_LITTLE_ENDIAN &&
      QEMU="mipsel -M malta"
  elif [ "$CROSS" == or1k ]; then
    KARCH=openrisc QEMU="or1k -M or1k-sim" KARGS=FIXME VMLINUX=vmlinux BUILTIN=1
    KCONF=OPENRISC_BUILTIN_DTB=\"or1ksim\",ETHOC,SERIO,SERIAL_8250,SERIAL_8250_CONSOLE,SERIAL_OF_PLATFORM
  elif [ "$CROSS" == powerpc ]; then
    KARCH=powerpc QEMU="ppc -M g3beige" KARGS=ttyS0 VMLINUX=vmlinux
    KCONF=ALTIVEC,PPC_PMAC,PPC_OF_BOOT_TRAMPOLINE,ATA,ATA_SFF,ATA_BMDMA,PATA_MACIO,BLK_DEV_SD,MACINTOSH_DRIVERS,ADB,ADB_CUDA,NET_VENDOR_NATSEMI,NET_VENDOR_8390,NE2K_PCI,SERIO,SERIAL_PMACZILOG,SERIAL_PMACZILOG_TTYS,SERIAL_PMACZILOG_CONSOLE,BOOTX_TEXT
  elif [ "$CROSS" == powerpc64 ] || [ "$CROSS" == powerpc64le ]; then
    KARCH=powerpc QEMU="ppc64 -M pseries -vga none" KARGS=hvc0
    VMLINUX=vmlinux
    KCONF=PPC64,PPC_PSERIES,PPC_OF_BOOT_TRAMPOLINE,BLK_DEV_SD,SCSI_LOWLEVEL,SCSI_IBMVSCSI,ATA,NET_VENDOR_IBM,IBMVETH,HVC_CONSOLE,PPC_TRANSACTIONAL_MEM,PPC_DISABLE_WERROR,SECTION_MISMATCH_WARN_ONLY
    [ "$CROSS" == powerpc64le ] && KCONF=$KCONF,CPU_LITTLE_ENDIAN
  elif [ "$CROSS" = s390x ]; then
    QEMU="s390x" KARCH=s390 VMLINUX=arch/s390/boot/bzImage
    KCONF=MARCH_Z900,PACK_STACK,VIRTIO_NET,VIRTIO_BLK,SCLP_TTY,SCLP_CONSOLE,SCLP_VT220_TTY,SCLP_VT220_CONSOLE,S390_GUEST
  elif [ "$CROSS" == sh2eb ]; then
    BUILTIN=1 KARCH=sh VMLINUX=vmlinux
    KCONF=CPU_SUBTYPE_J2,CPU_BIG_ENDIAN,SH_JCORE_SOC,SMP,BINFMT_ELF_FDPIC,JCORE_EMAC,SERIAL_UARTLITE,SERIAL_UARTLITE_CONSOLE,HZ_100,CMDLINE_OVERWRITE,SPI,SPI_JCORE,MMC,PWRSEQ_SIMPLE,MMC_BLOCK,MMC_SPI,BINMT_FLAT,BINFMT_MISC,DNOTIFY,INOTIFY_USER,FUSE_FS,I2C,I2C_HELPER_AUTO,LOCALVERSION_AUTO,MTD,MTD_SPI_NOR,MTD_SST25L,MTD_OF_PARTS,POSIX_MQUEUE,SYSVIPC,UEVENT_HELPER,UIO,UIO_PDRV_GENIRQ,FLATMEM_MANUAL,MEMORY_START=0x10000000,CMDLINE=\"console=ttyUL0\ earlycon\"
    KCONF+=,BFP_SYSCALL,CRYPTO_DES,CRYPTO_DH,CRYPTO_ECHAINIV,CRYPTO_LZO,CRYPTO_MANAGER_DISABLE_TESTS,CRYPTO_RSA,CRYPTO_SHA1,CRYPTO_SHA3,INET_DIAG,SERIAL_8250
    # TODO NET_9P,9P_FS fails to boot in 6.3, unaligned access?
  elif [ "$CROSS" == sh4 ]; then
    QEMU="sh4 -M r2d -serial null -serial mon:stdio" KARCH=sh
    KARGS="ttySC1 noiotrap" VMLINUX=arch/sh/boot/zImage
    KCONF=CPU_SUBTYPE_SH7751R,MMU,VSYSCALL,SH_FPU,SH_RTS7751R2D,RTS7751R2D_PLUS,SERIAL_SH_SCI,SERIAL_SH_SCI_CONSOLE,PCI,NET_VENDOR_REALTEK,8139CP,PCI,BLK_DEV_SD,ATA,ATA_SFF,ATA_BMDMA,PATA_PLATFORM,BINFMT_ELF_FDPIC,BINFMT_FLAT,MEMORY_START=0x0c000000
#see also SPI SPI_SH_SCI MFD_SM501 RTC_CLASS RTC_DRV_R9701 RTC_DRV_SH RTC_HCTOSYS
  else die "Unknown \$CROSS=$CROSS"
  fi

  # Write the qemu launch script
  if [ -n "$QEMU" ]; then
    [ -z "$BUILTIN" ] && INITRD='-initrd "$DIR"/initramfs.cpio.gz'
    { echo DIR='"$(dirname $0)";' qemu-system-"$QEMU" -m 256 '"$@"' $QEMU_MORE \
        -nographic -no-reboot -kernel '"$DIR"'/linux-kernel $INITRD \
        ${DTB:+-dtb '"$DIR"'/linux.dtb} \
        "-append \"HOST=$CROSS console=$KARGS \$KARGS\"" &&
      echo "echo -e '\\e[?7h'"
    } > "$OUTPUT"/run-qemu.sh &&
    chmod +x "$OUTPUT"/run-qemu.sh || exit 1
  fi

  announce "linux-$KARCH"
  pushd "$LINUX" && make distclean && popd &&
  cp -sfR "$LINUX" "$TEMP/linux" && pushd "$TEMP/linux" &&

  # Write linux-miniconfig
  mkdir -p "$OUTDOC" &&
  { echo "# make ARCH=$KARCH allnoconfig KCONFIG_ALLCONFIG=linux-miniconfig"
    echo -e "# make ARCH=$KARCH -j \$(nproc)\n# boot $VMLINUX\n\n"

    # Expand list of =y symbols, first generic then architecture-specific
    for i in BINFMT_ELF,BINFMT_SCRIPT,PANIC_TIMEOUT=1,NO_HZ,HIGH_RES_TIMERS,BLK_DEV,BLK_DEV_INITRD,RD_GZIP,BLK_DEV_LOOP,EXT4_FS,EXT4_USE_FOR_EXT2,VFAT_FS,FAT_DEFAULT_UTF8,NLS_CODEPAGE_437,NLS_ISO8859_1,MISC_FILESYSTEMS,SQUASHFS,SQUASHFS_XATTR,SQUASHFS_ZLIB,DEVTMPFS,DEVTMPFS_MOUNT,TMPFS,TMPFS_POSIX_ACL,NET,PACKET,UNIX,INET,IPV6,NETDEVICES,NET_CORE,NETCONSOLE,ETHERNET,COMPAT_32BIT_TIME,EARLY_PRINTK,IKCONFIG,IKCONFIG_PROC "$KCONF" ${MODULES+MODULES,MODULE_UNLOAD} "$KEXTRA" ; do
      echo "$i" >> "$OUTDOC"/linux-microconfig
      echo "# architecture ${X:-independent}"
      csv2cfg "$i" y
      X=${X:+extra} X=${X:-specific}
    done
    [ -n "$BUILTIN" ] && echo -e CONFIG_INITRAMFS_SOURCE="\"$OUTPUT/fs\""
    for i in $MODULES; do csv2cfg "$i" m; done
    echo "$KERNEL_CONFIG"
  } > "$OUTDOC/linux-miniconfig" &&
  make ARCH=$KARCH allnoconfig KCONFIG_ALLCONFIG="$OUTDOC/linux-miniconfig" &&

  # Second config pass to remove stupid kernel defaults
  # See http://lkml.iu.edu/hypermail/linux/kernel/1912.3/03493.html
  sed -e 's/# CONFIG_EXPERT .*/CONFIG_EXPERT=y/' -e "$(sed -E -e '/^$/d' \
    -e 's@([^,]*)($|,)@/^CONFIG_\1=y/d;$a# CONFIG_\1 is not set\n@g' \
       <<< VT,SCHED_DEBUG,DEBUG_MISC,X86_DEBUG_FPU)" -i .config &&
  yes "" | make ARCH=$KARCH oldconfig > /dev/null &&
  cp .config "$OUTDOC/linux-fullconfig" &&

  # Build kernel. Copy config, device tree binary, and kernel binary to output
  make ARCH=$KARCH CROSS_COMPILE="$CROSS_COMPILE" -j $(nproc) all || exit 1
  [ -n "$DTB" ] && { cp "$DTB" "$OUTPUT/linux.dtb" || exit 1 ;}
  if [ -n "$MODULES" ]; then
    make ARCH=$KARCH INSTALL_MOD_PATH=modz modules_install &&
      (cd modz && find lib/modules | cpio -o -H newc -R +0:+0 ) | gzip \
       > "$OUTDOC/modules.cpio.gz" || exit 1
  fi
  cp "$VMLINUX" "$OUTPUT"/linux-kernel && cd .. && rm -rf linux && popd ||exit 1
fi

# clean up and package root filesystem for initramfs.
if [ -z "$BUILTIN" ]; then
  announce initramfs
  { (cd "$ROOT" && find . -printf '%P\n' | cpio -o -H newc -R +0:+0 ) || exit 1
    ! test -e "$OUTDOC/modules.cpio.gz" || zcat $_;} | gzip \
    > "$OUTPUT"/initramfs.cpio.gz || exit 1
fi

mv "$LOG".{n,y} && echo "Output is in $OUTPUT"
rmdir "$TEMP" 2>/dev/null || exit 0 # remove if empty, not an error
