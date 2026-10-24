// ---------------------------------------------------------------------------------------------------------------------
// Gondomania for MiSTer - Copyright (C) 2026 Eggsecutioner528
// Licensed under the GNU General Public License, version 2 or (at your option) any later version (see LICENSE).
// Any copy or derived work must keep this notice, name the author and be published with its complete source under the same license.
// Provenance mark GDM-6fcdb4efa097
// ---------------------------------------------------------------------------------------------------------------------
// ROM download for Gondomania: the HPS streams the MRA bytes (ioctl_addr / ioctl_dout / ioctl_wr), this module sends each byte where it belongs.
// One MRA holds every version of the game (US, World, Japan); the OSD picks the version. Layout of the stream (plain MAME region order, no
// interleave, written by tools/make_mra.py):
//   000000-05FFFF  background tile ROM, MAME region (shared by all versions) -> SDRAM, reordered into 64 bit row words (gondo_gfxrom)
//   then one block of 0B9000 bytes for each version v = 0, 1, 2, starting at 060000 + v * 0B9000:
//     +000000-047FFF  main CPU banks (16 x 16 KB), then the fixed 32 KB ROM (8000-FFFF) -> staging area in SDRAM
//     +048000-04FFFF  character ROM, 32 KB                                           -> staging area
//     +050000-0AFFFF  sprite ROM, MAME region                                        -> SDRAM sprite rows of version v (one copy per version)
//     +0B0000-0B0FFF  i8751 MCU ROM, 4 KB                                            -> staging area
//     +0B1000-0B8FFF  sound CPU ROM, 32 KB                                           -> staging area
// The staging area (SDRAM, bank 2) keeps the program, character, MCU and sound ROMs of every version in a raw copy, 059000 bytes per version
// (main 000000, character 048000, MCU 050000, sound 051000 inside it). gondo_vsel copies the selected version from there into the block RAMs
// of the core every time the core restarts, so the version can be changed in the OSD without a new download.
// The 16 x 16 tile and sprite regions hold four bit planes in quarters of 0x18000 bytes (plane 3 first, plane 0 last, as MAME's gfx layout
// reads them); within a plane every tile takes 32 bytes, bytes 0-15 are the right half (x 8-15) of rows 0-15 and bytes 16-31 the left half.
// The video block wants one 64 bit word per tile row: byte 0 (MSB) = plane 0 left, 1 = plane 0 right, 2 = plane 1 left, ... 7 = plane 3 right.
module gondo_loader (
    input             clk,
    input             ioctl_download,
    input             ioctl_wr,
    input      [24:0] ioctl_addr,
    input      [7:0]  ioctl_dout,
    output reg        ioctl_wait,

    // every byte goes through gondo_gfxrom's write interface: hold gw_valid and the other gw_ outputs until gw_ack pulses
    output reg        gw_valid,
    output reg [1:0]  gw_kind,         // 0 = tile ROM row byte, 1 = sprite ROM row byte, 2 = raw byte in the staging area
    output reg [1:0]  gw_ver,          // version (sprite rows are kept once per version)
    output reg [20:0] gw_off,          // rows: {row (16 bits), byte index (3 bits)}; staging: byte address
    output reg [7:0]  gw_data,
    input             gw_ack
);
    localparam [24:0] V0 = 25'h060000, VS = 25'h0B9000;

    wire [24:0] a = ioctl_addr;
    wire        in_tile = a < V0;
    wire [24:0] b  = a - V0;
    wire [1:0]  v  = (b < VS) ? 2'd0 : (b < 2 * VS) ? 2'd1 : (b < 3 * VS) ? 2'd2 : 2'd3;       // 3 = beyond the last version
    wire [24:0] r  = b - ((v == 2'd1) ? VS : (v == 2'd2) ? 2 * VS : 25'd0);                     // offset inside the version block
    wire        in_raw = !in_tile && v != 2'd3 && (r < 25'h050000 || (r >= 25'h0B0000 && r < 25'h0B9000));
    wire        in_spr = !in_tile && v != 2'd3 && r >= 25'h050000 && r < 25'h0B0000;
    wire [20:0] soff = (r < 25'h050000) ? r[20:0] : (r[20:0] - 21'h060000);                    // offset inside the version's staging block
    wire [20:0] sadr = soff + ((v == 2'd1) ? 21'h059000 : (v == 2'd2) ? 21'h0B2000 : 21'd0);    // staging area address

    wire [19:0] o   = in_tile ? a[19:0] : (r[19:0] - 20'h50000);                                // 0 .. 0x5FFFF inside the tile or sprite region
    wire [1:0]  q   = (o >= 20'h48000) ? 2'd3 : (o >= 20'h30000) ? 2'd2 : (o >= 20'h18000) ? 2'd1 : 2'd0;     // quarter of the region
    wire [19:0] k   = o - (q == 2'd3 ? 20'h48000 : q == 2'd2 ? 20'h30000 : q == 2'd1 ? 20'h18000 : 20'h00000); // byte within the plane
    wire [1:0]  pl  = 2'd3 - q;                                                       // bit plane number, plane 0 = most significant pixel bit
    wire [11:0] t   = k[16:5];                                                        // tile 0..3071
    wire [4:0]  j   = k[4:0];
    wire [3:0]  y   = j[3:0];
    wire        rgt = ~j[4];                                                          // bytes 0-15 hold the right half
    wire [2:0]  bi  = {pl, rgt};                                                      // byte index in the row word, 0 = most significant

    always @(posedge clk) begin
        if (ioctl_download && ioctl_wr) begin
            if (in_tile || in_spr) begin
                gw_valid <= 1'b1; gw_kind <= in_tile ? 2'd0 : 2'd1; gw_ver <= in_tile ? 2'd0 : v; gw_data <= ioctl_dout;
                gw_off   <= {2'b00, t, y, bi};
                ioctl_wait <= 1'b1;
            end else if (in_raw) begin
                gw_valid <= 1'b1; gw_kind <= 2'd2; gw_ver <= v; gw_data <= ioctl_dout;
                gw_off   <= sadr;
                ioctl_wait <= 1'b1;
            end
        end
        if (gw_ack) begin gw_valid <= 1'b0; ioctl_wait <= 1'b0; end
    end
    initial begin gw_valid = 0; ioctl_wait = 0; gw_kind = 0; gw_ver = 0; gw_off = 0; gw_data = 0; end
endmodule
