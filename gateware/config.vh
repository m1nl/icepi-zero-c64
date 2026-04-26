`ifndef config_vh_
`define config_vh_

`define VERSION_MAJOR 8'd0
`define VERSION_MINOR 8'd0

// Branch
`define VARIANT_NAME1   8'h4D  // M
`define VARIANT_NAME2   8'h41  // A
`define VARIANT_NAME3   8'h49  // I
`define VARIANT_NAME4   8'h4E  // N

// Board
`define VARIANT_SUFFIX_1 8'h4C // L
`define VARIANT_SUFFIX_2 8'h47 // G

// Variant
`define VARIANT_SUFFIX_3 8'h2B // -
`define VARIANT_SUFFIX_4 8'h44 // D
`define VARIANT_SUFFIX_5 8'h56 // V
`define VARIANT_SUFFIX_6 8'h53 // S
`define VARIANT_SUFFIX_7 8'h0
`define VARIANT_SUFFIX_8 8'h0

// `define WITH_EXTENSIONS 1
// `define WITH_RAM 1
// `define WITH_4K 1
`define HAVE_SYNC_MODULE 1
`define WITH_DVI 1
// `define HIRES_MODES 1
// `define HIRES_RESET 1
`define PAL_27MHZ 1
`define NTSC_26MHZ 1

`define RAS_CAS_CUSTOM 1

// PAL CAS/RAS rise/fall times based on PAL dot4x clock
`define PAL_RAS_RISE_P 15
`define PAL_RAS_RISE_N 0
`define PAL_CAS_RISE_P 15
`define PAL_CAS_RISE_N 0

`define PAL_RAS_FALL_P 3
`define PAL_RAS_FALL_N 3
`define PAL_MUX_COL 4
`define PAL_CAS_FALL_P 5
`define PAL_CAS_FALL_N 5

// NTSC CAS/RAS rise/fall times based on NTSC dot4x clock
`define NTSC_RAS_RISE_P 15
`define NTSC_RAS_RISE_N 0
`define NTSC_CAS_RISE_P 15
`define NTSC_CAS_RISE_N 0
`define NTSC_RAS_FALL_P 4
`define NTSC_RAS_FALL_N 5
`define NTSC_MUX_COL 6
`define NTSC_CAS_FALL_P 7
`define NTSC_CAS_FALL_N 6

// Other:
// NOTE: CAS_GLITCH [9] has worked the best for emulamer demos. Works well on
// both DRAM and static RAM. [10] starts to miss pixels on static RAM.  With
// [11] the characters will completely disappear.
`define CAS_GLITCH 9
// This can be this early because we calculate vic_addr in the same process
// block as where ado is set.  It can't be earlier because cycle type needs
// to be valid and it doesn't become valid until at least [2].
`define MUX_ROW 2

`endif // config_vh_
