# ZTE F6005 (CIG G-97CP) Port

Status: **early experiment** -- board selection infrastructure and stubs, not
yet bootable.

## Hardware

| Feature          | ODI DFP-34X-2C2 (SFP stick)      | ZTE F6005 (box ONT)              |
|------------------|-----------------------------------|----------------------------------|
| SoC              | RTL9601D (= RTL9602C die)        | RTL9601D (= RTL9602C die)       |
| CPU              | Lexra RLX5281, MIPS32             | Lexra RLX5281, MIPS32            |
| Flash            | 8 MB SPI NOR                      | 16 MB SPI NOR                   |
| RAM              | 32 MB                             | 32 MB                           |
| Host interface   | SFP SerDes (Fiber 1G / 2500BASE-X / HiSGMII) | HiSGMII to RTL8226B-VB 2.5GBase-T PHY |
| Optics           | SFP module (BOSA + laser driver)  | Internal BOSA, GPON MAC control  |
| TX-disable       | GPIO 13 (SoC)                     | GPON MAC TX-enable signal        |
| LAN PHY          | None (SFP edge)                   | RTL8226B-VB (MDIO on PAD_LED14/15) |
| Bootloader       | U-Boot (odi-oss's own or stock)   | CIG U-Boot 2011.12 (kept)       |
| Image format     | squashfs in tar                   | cramfs with embedded /uImage     |
| ODM              | ODI                               | CIG (G-97CP)                    |
| Luna SDK         | -                                 | 1.9.0                           |

## What exists

- `odi_board_data_f6005.c`: stub board-init replay, clock enable only.
  Needs a register capture from the serial console.
- `odi_board.c` with `ODI_BOARD_F6005`: the optics, laser and TX-disable
  verbs are stubs (no SFP module on a box ONT).
- `Makefile`: `ODI_BOARD=f6005` selects the F6005 board data.
- `image/build-f6005.sh`: cramfs image builder for the CIG bootloader.

## What is needed

### 1. Board-init register capture

Boot the stock F6005 firmware over serial (115200 8N1) and capture the
switch-core registers after boot:

```
# From U-Boot:
md.l 0xbb000000 0xc000

# Or from Linux:
devmem 0xbb000000 32    # and repeat for each offset
```

Compare against the RTL9602C reset defaults to find the board-init writes.
The stock `misc_mod.ko` / `rtk.ko` make these writes, in order, before the
GPON stack starts. The register sequence replaces the stub in
`odi_board_data_f6005.c`.

### 2. RTL8226B-VB PHY driver

The external 2.5GBase-T PHY needs:
- MDIO master init (PAD_LED14 = MDC, PAD_LED15 = MDIO)
- Firmware ramcode load (`Rtl8226b_a_uc_ramcode`, etc. from stock `lan_sds.ko`)
- PHY init sequence (`Rtl8226b_phy_init`)
- Link status polling or interrupt

The stock driver API (from `lan_sds.ko` strings):
```
Rtl8226b_phy_init(port)
Rtl8226_serdes_option_set / link_get / rst
Rtl8226_autoNegoAbility_get / set
Rtl8226_speed_get
Rtl8226_is_link
Rtl8226_eeeEnable_get / set
Rtl8226_2p5gLiteEnable_get / set
```

Source files in stock firmware: `nic_rtl8226.c`, `nic_rtl8226_init_merge_A_B.c`,
`lan_sds_main.c`.

### 3. HiSGMII LAN SerDes mode

The host-serdes.sh SerDes mode must be fixed to HiSGMII for the F6005.
The register sequence is already known (host-serdes.sh's `mode_vars hisgmii`
and `sds_seq hisgmii`), but on the SFP stick this is the host-side SerDes.
On the F6005 it is the LAN SerDes toward the RTL8226B.

The stock firmware calls `lan_sds_mode_set()` with mode "HiSGMII MAC".

### 4. Firmware replay tables

The sdkinit, modload and gpon_init replay tables may need adjustment.
The stock F6005 firmware uses Luna SDK 1.9.0 (the DFP-34X-2C2 uses an
older SDK). Some register values may differ between SDK versions.

### 5. Kernel command line

The CIG bootloader passes `root=/dev/mtdblock2` and loads to 0x80000000.
The kernel config may need adjustment for:
- cramfs support (CONFIG_CRAMFS=y)
- MTD partition table matching the F6005 flash layout
- Root filesystem on mtdblock2 (the image partition)

### 6. Network script

The F6005 always uses HiSGMII -- host-serdes.sh's mode selection (Fiber 1G
default, user-selectable) does not apply. The network.sh boot sequence
should force `host_forced=1` and apply the HiSGMII SerDes registers.

## Flash layout

```
Offset    Size      Name
0x000000  0x030000  Bootloader (CIG BSP V3.09.15)
0x030000  0x010000  Environment
0x040000  0x010000  Config
0x050000  0x1B0000  (reserved / config area)
0x200000  0x700000  Image A (cramfs)
0x900000  0x700000  Image B (cramfs)
```

## Building

```sh
# Kernel (once the cross-toolchain is set up):
make kernel ODI_BOARD=f6005

# Image:
./image/build-f6005.sh
```

## Flashing

Via serial console (CIG bootloader):
```
CIG# upgdimage 0 <tftp-ip> <filename>    # write Image A
CIG# set activeimage imagea               # boot Image A
CIG# reboot
```
