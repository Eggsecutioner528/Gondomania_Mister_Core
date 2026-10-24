// ---------------------------------------------------------------------------------------------------------------------
// Gondomania for MiSTer - Copyright (C) 2026 Eggsecutioner528
// Licensed under the GNU General Public License, version 2 or (at your option) any later version (see LICENSE).
// Any copy or derived work must keep this notice, name the author and be published with its complete source under the same license.
// Provenance mark GDM-48c552ff1b2a
// ---------------------------------------------------------------------------------------------------------------------
// Gondomania video: timing generator, line renderer (background, sprites, fix layer) and RM-C3 palette.
// Written from MAME's gondo video and verified against tools/render_frame.py, which matches MAME pixel for pixel.
//
// Raster (6 MHz pixel clock, from the 12 MHz crystal): 384 x 272, active 256 columns x lines 8..247, 57.44 Hz.
// The picture is the raw, unrotated raster of the vertical monitor (the game is ROT270); rotation for a CRT is done downstream.
//
// Structure: line N+1 is rendered into one line buffer while line N is output from the other. All memories are synchronous with one clock of
// read latency (address register loaded at edge E0, data register loaded at E1, usable at E2). The module runs from clk with a pixel clock
// enable every 8 clocks (48 MHz): the renderer has 8 x 384 = 3072 clocks per line.
// Graphics ROMs are read a whole tile row at a time (layout made by tools/make_roms.py).
module gondo_video #(
    parameter INIT_H = 0, INIT_V = 0     // raster position at reset release (the CPU simulation uses it to line the first NMI up with MAME)
) (
    input             clk,
    input             rst,
    input             pxl_cen,          // one clk wide, once per pixel (6 MHz)

    // CPU written video registers
    input      [8:0]  scrx,             // background scroll X (3818 low byte, 3828 bit 0 = bit 8)
    input      [8:0]  scry,             // background scroll Y (3820 low byte, 3828 bit 1 = bit 8)
    // sync pulse positions (the CRT position options move them; the picture itself does not move): hs on [hs_start, hs_end), vs on [vs_start, vs_end)
    // in pixels and lines of the 384 x 272 raster, vs wrapping around the frame when vs_end < vs_start
    input      [8:0]  hs_start, hs_end, vs_start, vs_end,

    // memories (read ports)
    output reg [9:0]  fix_addr,  input [15:0] fix_q,      // fix layer tile RAM, 1024 words (1800-1FFF)
    output reg [9:0]  bg_addr,   input [15:0] bg_q,       // background tile RAM, 1024 words (2000-27FF)
    output reg [9:0]  spr_addr,  input [15:0] spr_q,      // sprite buffer, 1024 words
    output reg [9:0]  pal_addr,  input [15:0] pal_q,      // palette, 1024 words {ext, low}
    output reg [12:0] char_row_addr, input [23:0] char_row_q,   // char ROM rows {char, row}: plane0, plane1, plane2 bytes
    output reg [15:0] tile_row_addr, input [63:0] tile_row_q, input tile_ok,   // background tile ROM rows {tile, row}; ok = q holds the row of the current address
    output reg [15:0] spr_row_addr,  input [63:0] spr_row_q,  input spr_ok,     // sprite ROM rows {tile, row} (SDRAM: the renderer waits for ok)

    // video out (registered, one pixel after the counters)
    output reg [7:0]  r, g, b,
    output reg        hs, vs, hblank, vblank, de,
    output            vbl_start,            // pulses once per frame when vblank starts (line 248)
    output            vbl_cpu               // vblank as the main CPU sees it (NMI source, bit 7 of 380E): high on lines 248..271 and 0..7
);
    initial begin
        bg_addr = 0; spr_addr = 0; fix_addr = 0; pal_addr = 0; char_row_addr = 0; tile_row_addr = 0; spr_row_addr = 0;
        r = 0; g = 0; b = 0; hs = 0; vs = 0; hblank = 0; vblank = 0; de = 0;
    end

    // ---------------------------------------------------------------- timing
    localparam HTOTAL = 384, VTOTAL = 272, HACT = 256, V0 = 8, V1 = 248;
    reg [8:0] hcnt = INIT_H, vcnt = INIT_V;
    always @(posedge clk) begin
        if (rst) begin hcnt <= INIT_H; vcnt <= INIT_V; end
        else if (pxl_cen) begin
            if (hcnt == HTOTAL - 1) begin
                hcnt <= 0;
                vcnt <= (vcnt == VTOTAL - 1) ? 9'd0 : vcnt + 1'd1;
            end else hcnt <= hcnt + 1'd1;
        end
    end
    wire line_start = pxl_cen && hcnt == HTOTAL - 1;       // the edge at which a new line begins
    assign vbl_start = line_start && vcnt == V1 - 1;
    assign vbl_cpu   = !(vcnt >= V0 && vcnt < V1);

    // ---------------------------------------------------------------- line buffers {prio[1:0], palette index[9:0]}
    // prio: 1 = background layer 1 pixel (pens 0-7), 2 = background layer 0 pixel (pens 8-15), 3 = a sprite pixel was seen here
    reg [11:0] lb0 [0:255];
    reg [11:0] lb1 [0:255];
    reg        rsel = 0;                                    // 0: lb0 is displayed and lb1 rendered, 1: the other way round
    always @(posedge clk) if (line_start) rsel <= ~rsel;
    reg        lbw_we;
    reg [7:0]  lbw_x;
    reg [11:0] lbw_d;
    always @(posedge clk) if (lbw_we) begin
        if (rsel) lb0[lbw_x] <= lbw_d; else lb1[lbw_x] <= lbw_d;
    end
    reg [11:0] lbr_q;                                       // display side read
    always @(posedge clk) lbr_q <= rsel ? lb1[hcnt[7:0]] : lb0[hcnt[7:0]];
    reg [7:0]  wrd_x;                                       // render side read (sprite priority test)
    reg [11:0] wrd_q;
    always @(posedge clk) wrd_q <= rsel ? lb0[wrd_x] : lb1[wrd_x];

    // ---------------------------------------------------------------- line renderer
    wire [8:0] target    = (vcnt == VTOTAL - 1) ? 9'd0 : vcnt + 1'd1;   // the line to render: the one after the line being output
    wire       target_ok = !target[8];                                  // the tilemap space is y 0..255
    wire [7:0] ty        = target[7:0];

    localparam S_IDLE = 0, S_DONE = 1,
               S_B_ADDR = 2, S_B_WAIT = 3, S_B_WORD = 4, S_B_ROW1 = 5, S_B_ROW2 = 6, S_B_OUT = 7,
               S_SP_INIT = 8, S_SP_A0 = 9, S_SP_W0 = 10, S_SP_R0 = 11, S_SP_AW = 12, S_SP_WW = 13, S_SP_RW = 14, S_SP_DEC = 15,
               S_SP_ROW1 = 16, S_SP_ROW2 = 17, S_SP_PIX = 18, S_SP_NEXT = 19,
               S_F_ADDR = 20, S_F_WAIT = 21, S_F_WORD = 22, S_F_ROW1 = 23, S_F_ROW2 = 24, S_F_OUT = 25;
    reg [4:0]  st = S_IDLE;
    reg [8:0]  lscx, lscy;               // scroll values latched at the start of the line

    function [11:0] mod3072(input [11:0] c);        // tile numbers wrap at the 3072 tiles the ROMs hold
        mod3072 = (c >= 12'd3072) ? c - 12'd3072 : c;
    endfunction
    // a 16 x 16 tile row word: byte 0 (bits 63:56) = plane 0 left half (x 0-7), byte 1 = plane 0 right half (x 8-15), byte 2 = plane 1 left, ...
    function [7:0] rowbyte(input [63:0] w, input [1:0] plane, input half);
        rowbyte = w[63 - 8 * (2 * plane + half) -: 8];
    endfunction

    // --- background
    wire [8:0] ys = {1'b0, ty} + lscy;               // map row (512 high map, wraps)
    reg [4:0]  bk;                                   // tile counter within the line, 0..16
    wire [4:0] bcol = lscx[8:4] + bk;                // map tile column
    reg [3:0]  bcolor;
    reg [63:0] bbytes;
    reg [3:0]  bp;                                   // pixel within the tile row
    wire [2:0] bbit = 3'd7 - bp[2:0];
    wire [7:0] bp0 = rowbyte(bbytes, 2'd0, bp[3]), bp1 = rowbyte(bbytes, 2'd1, bp[3]), bp2 = rowbyte(bbytes, 2'd2, bp[3]), bp3 = rowbyte(bbytes, 2'd3, bp[3]);
    wire [3:0] bpen = {bp0[bbit], bp1[bbit], bp2[bbit], bp3[bbit]};
    wire signed [10:0] bx = $signed({1'b0, bk, 4'b0}) + $signed({7'b0, bp}) - $signed({7'b0, lscx[3:0]});

    // --- sprites
    reg [7:0]  si;                                   // sprite number, 0 up to 255 (the last one ends up on top)
    reg [1:0]  wi;
    reg [15:0] w0, w1, w2, w3;
    reg [4:0]  sdy;                                  // row within the sprite (0..31)
    reg        sfx, sbehind;
    reg [3:0]  scolour;
    reg signed [9:0] sX;
    reg [63:0] sbytes;
    reg [4:0]  pc;
    wire [8:0] s0_v = spr_q[8:0] + (spr_q[11] ? 9'd32 : 9'd16);
    wire signed [9:0]  s0_Y  = 10'sd256 - $signed({1'b0, s0_v});
    wire signed [10:0] s0_dy = $signed({3'b0, ty}) - $signed({s0_Y[9], s0_Y});
    wire s0_vis = spr_q[15] && s0_dy >= 0 && s0_dy < (spr_q[11] ? 11'sd32 : 11'sd16);
    // decode of the captured words
    wire        d_extra = w0[11];
    wire        d_fy = w1[1], d_fx = w1[2];
    wire [11:0] d_code = d_extra ? {w3[11:1], 1'b0} : w3[11:0];
    wire [11:0] d_top = (d_extra && d_fy) ? (d_code | 12'd1) : d_code;
    wire [11:0] d_bot = (d_extra && d_fy) ? d_code : (d_code | 12'd1);
    wire [11:0] d_sel = (d_extra && sdy[4]) ? d_bot : d_top;
    wire [3:0]  d_ry = d_fy ? ~sdy[3:0] : sdy[3:0];
    wire [8:0]  d_xs = w2[8:0] + 9'd16;
    wire signed [9:0] d_X = 10'sd256 - $signed({1'b0, d_xs});
    // pixel pipeline
    wire [3:0] pcol = sfx ? 4'd15 - pc[3:0] : pc[3:0];
    wire [2:0] pbit = 3'd7 - pcol[2:0];
    wire [7:0] sp0 = rowbyte(sbytes, 2'd0, pcol[3]), sp1 = rowbyte(sbytes, 2'd1, pcol[3]), sp2 = rowbyte(sbytes, 2'd2, pcol[3]), sp3 = rowbyte(sbytes, 2'd3, pcol[3]);
    wire [3:0] ppen = {sp0[pbit], sp1[pbit], sp2[pbit], sp3[pbit]};
    wire signed [10:0] pX = $signed({sX[9], sX}) + $signed({7'b0, pc[3:0]});
    reg        p1_v, p2_v, p1_beh, p2_beh;
    reg [7:0]  p1_x, p2_x;
    reg [9:0]  p1_idx, p2_idx;

    // --- fix layer
    reg [4:0]  tx;
    reg [2:0]  fcolor;
    reg [23:0] fbytes;                               // {plane 0, plane 1, plane 2} bytes of the row
    reg [2:0]  px;
    wire [2:0] py = ty[2:0];
    wire [2:0] fbit = 3'd7 - px;
    wire [2:0] fpen = {fbytes[{2'b10, fbit}], fbytes[{2'b01, fbit}], fbytes[{2'b00, fbit}]};

    always @(posedge clk) begin
        lbw_we <= 1'b0;
        p1_v <= 1'b0; p2_v <= p1_v; p2_x <= p1_x; p2_idx <= p1_idx; p2_beh <= p1_beh;
        if (rst) st <= S_IDLE;
        else if (line_start) begin st <= target_ok ? S_B_ADDR : S_DONE; bk <= 0; lscx <= scrx; lscy <= scry; end
        else case (st)
            // ---- background: 17 tiles of 16 x 16, every pixel is written (pens 0-7 priority 1, pens 8-15 priority 2)
            S_B_ADDR: begin bg_addr <= {ys[8:4], bcol}; st <= S_B_WAIT; end
            S_B_WAIT: st <= S_B_WORD;
            S_B_WORD: begin bcolor <= bg_q[15:12]; tile_row_addr <= {mod3072(bg_q[11:0]), ys[3:0]}; st <= S_B_ROW1; end
            S_B_ROW1: if (tile_ok) st <= S_B_ROW2;
            S_B_ROW2: begin bbytes <= tile_row_q; bp <= 0; st <= S_B_OUT; end
            S_B_OUT: begin
                if (bx >= 0 && bx < 256) begin
                    lbw_x <= bx[7:0]; lbw_d <= {bpen[3] ? 2'b10 : 2'b01, 2'b11, bcolor, bpen}; lbw_we <= 1'b1;
                end
                bp <= bp + 1'd1;
                if (bp == 4'd15) begin
                    if (bk == 5'd16) st <= S_SP_INIT;
                    else begin bk <= bk + 1'd1; st <= S_B_ADDR; end
                end
            end
            // ---- sprites: sprite 255 first, sprite 0 last (it ends up on top); only those that cover the line are fetched
            S_SP_INIT: begin si <= 8'd0; st <= S_SP_A0; end
            S_SP_A0:   begin spr_addr <= {si, 2'b00}; st <= S_SP_W0; end
            S_SP_W0:   st <= S_SP_R0;
            S_SP_R0: begin
                w0 <= spr_q; sdy <= s0_dy[4:0];
                if (s0_vis) begin wi <= 2'd1; st <= S_SP_AW; end else st <= S_SP_NEXT;
            end
            S_SP_AW: begin spr_addr <= {si, wi}; st <= S_SP_WW; end
            S_SP_WW: st <= S_SP_RW;
            S_SP_RW: begin
                case (wi)
                    2'd1: w1 <= spr_q;
                    2'd2: w2 <= spr_q;
                    default: w3 <= spr_q;
                endcase
                if (wi == 2'd3) st <= S_SP_DEC; else begin wi <= wi + 1'd1; st <= S_SP_AW; end
            end
            S_SP_DEC: begin
                if (!w1[0]) st <= S_SP_NEXT;
                else begin
                    spr_row_addr <= {mod3072(d_sel), d_ry};
                    sfx <= d_fx; scolour <= w3[15:12]; sbehind <= w3[15]; sX <= d_X;
                    st <= S_SP_ROW1;
                end
            end
            S_SP_ROW1: if (spr_ok) st <= S_SP_ROW2;
            S_SP_ROW2: begin sbytes <= spr_row_q; pc <= 0; st <= S_SP_PIX; end
            S_SP_PIX: begin
                // issue: look at what the line buffer holds under this pixel
                if (pc < 5'd16) begin
                    wrd_x <= pX[7:0];
                    p1_v <= (ppen != 4'd0) && pX >= 0 && pX < 256;
                    p1_x <= pX[7:0]; p1_idx <= {2'b01, scolour, ppen}; p1_beh <= sbehind;
                end
                // decide, two clocks after the issue, when the line buffer value has arrived: hidden pixels still mark the priority (MAME)
                if (p2_v) begin
                    lbw_x <= p2_x; lbw_we <= 1'b1;
                    lbw_d <= (p2_beh && wrd_q[11:10] == 2'b10) ? {2'b11, wrd_q[9:0]} : {2'b11, p2_idx};
                end
                pc <= pc + 1'd1;
                if (pc == 5'd18) st <= S_SP_NEXT;
            end
            S_SP_NEXT: begin
                if (si == 8'd255) begin st <= S_F_ADDR; tx <= 0; end
                else begin si <= si + 1'd1; st <= S_SP_A0; end
            end
            // ---- fix layer: 32 tiles of 8 x 8, pen 0 transparent, on top of everything
            S_F_ADDR: begin fix_addr <= {ty[7:3], tx}; st <= S_F_WAIT; end
            S_F_WAIT: st <= S_F_WORD;
            S_F_WORD: begin fcolor <= fix_q[14:12]; char_row_addr <= {fix_q[9:0], py}; st <= S_F_ROW1; end
            S_F_ROW1: st <= S_F_ROW2;
            S_F_ROW2: begin fbytes <= char_row_q; px <= 0; st <= S_F_OUT; end
            S_F_OUT: begin
                if (fpen != 3'd0) begin lbw_x <= {tx, px}; lbw_d <= {2'b11, 4'b0, fcolor, fpen}; lbw_we <= 1'b1; end
                px <= px + 1'd1;
                if (px == 3'd7) begin
                    if (tx == 5'd31) st <= S_DONE;
                    else begin tx <= tx + 1'd1; st <= S_F_ADDR; end
                end
            end
            default: ;
        endcase
    end

    // ---------------------------------------------------------------- output: line buffer -> palette -> RM-C3 weighting
    always @(posedge clk) pal_addr <= lbr_q[9:0];
    function [7:0] comp4(input [3:0] n);        // DECO RM-C3 resistor weights 220, 470, 1k, 2.2k ohm: 0x8f 0x43 0x1f 0x0e
        comp4 = (n[0] ? 8'h0e : 8'h00) + (n[1] ? 8'h1f : 8'h00) + (n[2] ? 8'h43 : 8'h00) + (n[3] ? 8'h8f : 8'h00);
    endfunction
    wire act_h = hcnt < HACT;
    wire act_v = vcnt >= V0 && vcnt < V1;
    always @(posedge clk) if (pxl_cen) begin
        de     <= act_h && act_v;
        hblank <= !act_h;
        vblank <= !act_v;
        hs     <= hcnt >= hs_start && hcnt < hs_end;
        vs     <= (vs_start < vs_end) ? (vcnt >= vs_start && vcnt < vs_end) : (vcnt >= vs_start || vcnt < vs_end);
        if (act_h && act_v) begin
            r <= comp4(pal_q[3:0]); g <= comp4(pal_q[7:4]); b <= comp4(pal_q[11:8]);
        end else begin r <= 8'd0; g <= 8'd0; b <= 8'd0; end
    end
endmodule
