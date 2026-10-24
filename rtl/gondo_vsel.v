// ---------------------------------------------------------------------------------------------------------------------
// Gondomania for MiSTer - Copyright (C) 2026 Eggsecutioner528
// Licensed under the GNU General Public License, version 2 or (at your option) any later version (see LICENSE).
// Any copy or derived work must keep this notice, name the author and be published with its complete source under the same license.
// Provenance mark GDM-f6d3d72f910d
// ---------------------------------------------------------------------------------------------------------------------
// Game version selection for Gondomania. The download (gondo_loader) leaves the program, character, MCU and sound ROMs of every version raw in the
// SDRAM staging area; this module copies the selected version from there into the block RAMs of the core, 8 bytes per SDRAM read, and holds the core
// in reset (busy) meanwhile. It runs when a download has just finished and every time the OSD version changes afterwards, so the version can be
// switched without a new download (about 25 ms). It also tells the graphics ROM which version's sprite rows to use (ver_l, stable while the core runs).
// Staging block of one version (0x59000 bytes): main 000000-047FFF, character 048000-04FFFF, MCU 050000-050FFF, sound 051000-058FFF;
// the version v starts at v * 0x59000 (see gondo_loader.v).
module gondo_vsel (
    input             clk,
    input             ioctl_download,
    input      [1:0]  ver_sel,              // OSD choice, 0 .. 2 (3 is treated as 0)
    output reg        busy,                 // copying
    output            hold,                 // hold the core in reset: copying, or about to copy (no gap between the download and the copy)
    output reg [1:0]  ver_l,                // version in use (latched when the copy starts)

    // gondo_gfxrom staging read port
    output reg        rr_req,
    output     [20:0] rr_addr,
    input             rr_ack,
    input      [63:0] rr_q,

    // destinations (same ports the download used to drive)
    output reg        mrom_we,
    output reg [18:0] mrom_wa,
    output reg [7:0]  mrom_wd,
    output reg        crom_we,
    output reg [14:0] crom_wa,
    output reg [7:0]  crom_wd,
    output reg        mcu_we,
    output reg [11:0] mcu_wa,
    output reg [7:0]  mcu_wd,
    output reg        snd_we,
    output reg [14:0] snd_wa,
    output reg [7:0]  snd_wd
);
    localparam [15:0] NBLK = 16'h0B200;                 // 0x59000 / 8 blocks per version
    wire [1:0] sel = (ver_sel == 2'd3) ? 2'd0 : ver_sel;

    reg        dl_d = 1'b0, loaded = 1'b0;
    assign hold = busy | dl_d | (loaded & (sel != ver_l));
    reg [15:0] cnt = 16'd0;                             // block number inside the version
    reg [2:0]  bi = 3'd0;
    reg [63:0] data = 64'd0;
    reg        wr = 1'b0;                               // 0: wait for the read, 1: write the 8 bytes out
    wire [20:0] vb = (ver_l == 2'd1) ? 21'h059000 : (ver_l == 2'd2) ? 21'h0B2000 : 21'd0;
    assign rr_addr = vb + {2'b00, cnt, 3'b000};

    wire [18:0] soff = {cnt[15:0], 3'b000} + {16'd0, bi};   // byte offset inside the version's staging block
    wire [7:0]  byt  = data[{bi, 3'b000} +: 8];

    always @(posedge clk) begin
        dl_d <= ioctl_download;
        mrom_we <= 1'b0; crom_we <= 1'b0; mcu_we <= 1'b0; snd_we <= 1'b0;
        if (!busy) begin
            if (!ioctl_download && (dl_d || (loaded && sel != ver_l))) begin
                busy <= 1'b1; ver_l <= sel; cnt <= 16'd0; wr <= 1'b0; rr_req <= 1'b1;
            end
        end else if (!wr) begin
            if (rr_ack) begin data <= rr_q; rr_req <= 1'b0; bi <= 3'd0; wr <= 1'b1; end
        end else begin
            if (soff < 19'h48000)      begin mrom_we <= 1'b1; mrom_wa <= soff;               mrom_wd <= byt; end
            else if (soff < 19'h50000) begin crom_we <= 1'b1; crom_wa <= soff[14:0];         crom_wd <= byt; end   // 0x48000 is a multiple of 0x8000
            else if (soff < 19'h51000) begin mcu_we  <= 1'b1; mcu_wa  <= soff[11:0];         mcu_wd  <= byt; end
            else                       begin snd_we  <= 1'b1; snd_wa  <= soff[14:0] - 15'h1000; snd_wd <= byt; end
            bi <= bi + 1'd1;
            if (bi == 3'd7) begin
                wr <= 1'b0;
                if (cnt == NBLK - 1'd1) begin busy <= 1'b0; loaded <= 1'b1; end
                else begin cnt <= cnt + 1'd1; rr_req <= 1'b1; end
            end
        end
    end
    initial begin busy = 0; ver_l = 0; rr_req = 0; mrom_we = 0; crom_we = 0; mcu_we = 0; snd_we = 0; mrom_wa = 0; mrom_wd = 0; crom_wa = 0; crom_wd = 0;
                  mcu_wa = 0; mcu_wd = 0; snd_wa = 0; snd_wd = 0; end
endmodule
