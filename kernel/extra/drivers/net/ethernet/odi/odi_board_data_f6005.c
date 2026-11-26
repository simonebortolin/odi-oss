// SPDX-FileCopyrightText: 2026 Simone Bortolin
// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * odi_board_data_f6005.c -- odi_board_init_events[] for the ZTE F6005
 * (CIG G-97CP), an RTL9601D (= RTL9602C die) box ONT with an external
 * RTL8226B-VB 2.5GBase-T PHY on HiSGMII.
 *
 * The F6005 differs from the ODI DFP-34X-2C2 SFP stick:
 *   - host interface: HiSGMII to RTL8226B-VB, not SFP SerDes
 *   - no SFP module: no laser driver, no TX-disable GPIO, no I2C A2h
 *   - MDIO master on PAD_LED14/PAD_LED15 for the external PHY
 *   - different LED mapping (box ONT front-panel LEDs)
 *   - 16 MB SPI flash (vs 8 MB), 32 MB RAM
 *
 * TODO: the register values below are a STUB derived from code analysis
 * of the stock CIG firmware (lan_sds.ko, misc_mod.ko, rtk.ko). The
 * definitive sequence must be captured from a clean stock boot over the
 * serial console, as was done for the DFP-34X-2C2 (docs/SWITCH.md).
 *
 * What we know from the stock firmware strings and structures:
 *   - lan_sds_mode_set() configures HiSGMII MAC mode for the LAN SerDes
 *   - Rtl8226b_phy_init() loads ramcode into the RTL8226B-VB via MDIO
 *   - gMdrLedPhyG97CPTbl in misc_mod.ko has the LED table for this board
 *   - setup.sh loads: kvos.ko, misc_mod.ko (which loads lan_sds.ko etc.)
 *
 * Register decoding (switch-core offsets):
 *   0x0000001c  CHIP_INFO_DUMMY: chip variant / strap pins
 *   0x00023004  LED_SET_0_CTRL: LED port configuration
 *   0x00023018  LED_ACTIVE_LOW_CFG: LED active-low selection
 *   0x00023014  LED_SET_2_CTRL: LED port 2 (UTP1) configuration
 *   0x0001e05c  LED_SET_[n]_LED: individual LED mode registers
 *   0x0001e040  LED_MODE_LED[n]: LED mode (port 15, UTP0)
 *   0x0001e00c  LED_MODE_LED[n]: LED mode (port 2, UTP1)
 *   0x000000b8  PORT_ISOLATION: port isolation / forwarding
 *   0x000000c0  PORT_TRUNK: trunk configuration
 *   0x0000004c  I2C/MDIO master configuration
 */
#include "odi_board.h"

/*
 * STUB: the board init sequence below is intentionally EMPTY. Without a
 * register capture from the serial console of a stock F6005 boot, we
 * cannot replay the correct values. The SoC and switch-core bring up
 * with their reset defaults, and the stock CIG bootloader (U-Boot
 * 2011.12) initialises enough to reach a prompt.
 *
 * To capture the board init:
 *   1. Connect to the F6005 serial console (115200 8N1)
 *   2. Boot the stock firmware
 *   3. After boot, dump the switch-core registers with:
 *        devmem 0xbb000000 0x30000  (or the register read tool)
 *   4. Compare against the reset defaults to find the writes
 *
 * The three SoC writes the DFP-34X-2C2 makes (clock enable, GPIO bank 1
 * direction and data) will differ on the F6005: the I2C master setup is
 * replaced by MDIO pin mux, and the GPIO directions serve different board
 * functions (front-panel LEDs, reset lines, PHY reset).
 *
 * The minimum viable sequence for first boot:
 *   - SOC_CLK_RST_EN (0xb8000044): enable all needed clock domains
 *   - MDIO pin mux: configure PAD_LED14/PAD_LED15 for MDIO
 *   - PHY reset GPIO: deassert the RTL8226B-VB reset line
 */
const struct odi_replay_event odi_board_init_events[] = {
	/* Clock/reset enable -- same SoC, likely same value as DFP-34X-2C2 */
	{ .kind = ODI_REPLAY_SOC, .offset = 0xb8000044, .value = 0x0000035f },
};

const unsigned int odi_board_init_event_count =
	sizeof(odi_board_init_events) / sizeof(odi_board_init_events[0]);
