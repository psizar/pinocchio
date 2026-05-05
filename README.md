# Pinocchio

Pinocchio is a custom Virtual Machine Monitor (VMM) built in Zig, capable of booting a minimal Linux guest environment on macOS (Apple Silicon).

## Setup & Running

Follow these steps to set up the guest environment, compile the project, and run the VMM.

### 1. Get the Guest Kernel (vmlinuz)

We use the Debian installer's ARM64 kernel image. Download it into the `guest` directory:

```bash
curl -L -o guest/vmlinuz "http://ftp.debian.org/debian/dists/bookworm/main/installer-arm64/current/images/netboot/debian-installer/arm64/linux"
```

### 2. Get the BusyBox Binary

To provide a basic user-space shell, download a statically linked `busybox` binary for ARM64:

```bash
mkdir -p guest/tmp
curl -L -o guest/tmp/busybox.deb "http://ftp.cn.debian.org/debian/pool/main/b/busybox/busybox-static_1.37.0-10.1_arm64.deb"
mkdir guest/tmp/busybox-ext
tar -xf guest/tmp/busybox.deb -C guest/tmp/busybox-ext
tar -xf guest/tmp/busybox-ext/data.tar.xz -C guest/tmp/busybox-ext
```

### 3. Build the Initramfs

The `initramfs` contains our custom `/init` process and `busybox`. Follow these steps to prepare the directory and package it into a compressed archive.

```bash
# 1. Create the initramfs directory structure
mkdir -p guest/initramfs/bin guest/initramfs/proc guest/initramfs/dev guest/initramfs/sys

# 2. Compile the custom init program directly into the initramfs
zig build-exe guest/init.zig \
    -target aarch64-linux-musl \
    -O ReleaseSmall \
    -femit-bin=guest/initramfs/init

# 3. Copy the extracted busybox binary and set execute permissions
cp guest/tmp/busybox-ext/usr/bin/busybox guest/initramfs/bin/busybox
chmod +x guest/initramfs/bin/busybox

# 4. Create the compressed initramfs archive
cd guest/initramfs
find . | cpio -o -H newc | gzip > ../initramfs.cpio.gz
cd ../..
```

### 4. Compile and Run the VMM

Once the `guest/vmlinuz` and `guest/initramfs.cpio.gz` files are ready, you can build and run Pinocchio.

> [!IMPORTANT]
> The Device Tree (`pinocchio.dts`) needs the exact size of the `initramfs.cpio.gz` to set the memory boundaries for the guest.

1. **Get the size** of the initramfs archive:
   ```bash
   stat -f %z guest/initramfs.cpio.gz
   ```

2. **Update the Device Tree**:
   Compute the end address by adding the size to the start address (`0x44000000`) and update the `linux,initrd-end` value in `guest/pinocchio.dts`.

3. **Recompile the DTB**:
   ```bash
   dtc -I dts -O dtb -o guest/pinocchio.dtb guest/pinocchio.dts
   ```

4. **Run the VMM**:
   ```bash
   # Compile and run the VMM
   zig build run
   ```

To run the unit tests:

```bash
zig build test
```
