// ---------------------------------------------------------------------------------------------------------------------
// Gondomania for MiSTer - Copyright (C) 2026 Eggsecutioner528
// Licensed under the GNU General Public License, version 2 or (at your option) any later version (see LICENSE).
// Any copy or derived work must keep this notice, name the author and be published with its complete source under the same license.
// Provenance mark GDM-434e46845ba3
// ---------------------------------------------------------------------------------------------------------------------
// Gondomania main board: HD6309E, program ROM, RAMs, video block, interrupts and the i8751 mailbox glue.
// Everything runs from one 48 MHz clock; the CPU is clocked the way the GX7 cores clock theirs (12 MHz enable, E and Q at 3 MHz).
// Behaviour calibrated against MAME with sim/tb_cpu.v (same glue written for simulation): see docs/PROJECT_NOTES.md.
//
// Memory map (MAME ghostb.cpp gondo_state): 0000-17FF RAM, 1800-1FFF fix tile RAM, 2000-27FF background tile RAM,
// 2800-2BFF palette low, 2C00-2FFF palette extension, 3000-37FF sprite RAM, 3800-383B I/O, 4000-7FFF banked ROM, 8000-FFFF ROM.
`ifndef INT1_W
`define INT1_W 8'd32
`endif
module gondo_main #(
    parameter INIT_H = 0, INIT_V = 0
) (
    input             clk,                 // 48 MHz
    input             rst,

    // program ROM download: 0x00000-0x3FFFF = the 16 banks of 16 KB, 0x40000-0x47FFF = the fixed ROM at 8000-FFFF
    input             mrom_we,
    input      [18:0] mrom_wa,
    input      [7:0]  mrom_wd,
    // character ROM download: the 32 KB region as in MAME (quarter 3 = plane 0, quarter 2 = plane 1, quarter 1 = plane 2)
    input             crom_we,
    input      [14:0] crom_wa,
    input      [7:0]  crom_wd,

    // graphics ROM rows in SDRAM (see tools/make_roms.py for the layout)
    output     [15:0] tile_row_addr,
    input      [63:0] tile_row_q,
    input             tile_ok,
    output     [15:0] spr_row_addr,
    input      [63:0] spr_row_q,
    input             spr_ok,

    // inputs as the CPU reads them (active level as MAME reads them: 1 = released)
    input      [7:0]  io_3800, io_3801, io_380a, io_380b, io_380c, io_380d, io_380e, io_380f,

    // high score persistence (rtl/gondo_nvram.v): the CPU's work RAM writes go out, the restore's write comes in (used only on clocks where the CPU does not write)
    output            nv_cpu_we,
    output     [12:0] nv_cpu_addr,
    output     [7:0]  nv_cpu_data,
    input             nv_inj_we,
    input      [12:0] nv_inj_addr,
    input      [7:0]  nv_inj_data,
    input      [7:0]  coin_p3,         // i8751 port 3: bit 4 service, bit 5 coin 1, bit 6 coin 2, bit 7 coin 3 (active low, low nibble unused = 1)

    // i8751 MCU (jtframe_8751mcu on the FPGA, a C++ model in the Verilator test bench)
    input      [7:0]  mcu_p0_o, mcu_p1_o, mcu_p2_o, mcu_p3_o,
    output     [7:0]  mcu_p0_i, mcu_p1_i, mcu_p2_i, mcu_p3_i,
    output            mcu_int0n, mcu_int1n,

    // sound command (3810)
    output reg [7:0]  snd_cmd = 8'd0,
    output reg        snd_cmd_tog = 1'b0,

    // sync pulse positions (see gondo_video)
    input      [8:0]  hs_start, hs_end, vs_start, vs_end,

    // video, registered, raw unrotated raster
    output            pxl_cen,
    output     [7:0]  r, g, b,
    output            hs, vs, hblank, vblank, de,
    output            vbl_start,
    output            vbl_cpu,
    output            flip_screen          // 3830 bit 3 (cocktail flip); unused so far
);
    // ------------------------------------------------------------------ clocks
    // The CPU is clocked by E and Q, so it can only notice a reset while E and Q are running. The dividers therefore keep running during the first 255 clocks of every
    // reset (64 E cycles with nRESET low: the real board's E and Q circuit is not reset at all) and are then held at zero, so the start after the reset is as
    // deterministic as before. (They used to be held from the first clock of the reset: E and Q stopped, the 6309 never saw the reset and carried on where it was,
    // while the sound board, the MCU and the video were reset: the OSD reset dropped the music and left the game running.)
    reg [7:0] rst_age = 8'd0;
    always @(posedge clk) rst_age <= rst ? ((rst_age == 8'hFF) ? rst_age : rst_age + 1'd1) : 8'd0;
    wire rst_hold = rst && (rst_age == 8'hFF);
    reg [1:0] div = 2'd0;                              // 48 MHz -> 12 MHz enable
    always @(posedge clk) div <= rst_hold ? 2'd0 : div + 1'd1;
    wire cen12 = (div == 2'b11);
    reg [1:0] cdiv = 2'd0;                             // 12 MHz -> 3 MHz E and Q (same chain as the GX7 cores)
    always @(posedge clk) if (rst_hold) cdiv <= 2'd0; else if (cen12) cdiv <= cdiv + 1'd1;
    wire cpu_q = (cdiv == 2'b01 || cdiv == 2'b10);
    wire cpu_e = (cdiv == 2'b10 || cdiv == 2'b11);
    wire e_end = cen12 && cdiv == 2'b11;               // last clock of a bus cycle: the cycle that ends here is the one to act on

    reg [2:0] pdiv = 3'd0;                             // 48 MHz -> 6 MHz pixel clock enable
    always @(posedge clk) pdiv <= rst ? 3'd0 : pdiv + 1'd1;
    assign pxl_cen = (pdiv == 3'd7);

    // ------------------------------------------------------------------ CPU
    wire [7:0]  cpu_dout;
    wire [15:0] cpu_addr;
    wire        cpu_rw;
    reg  [7:0]  cpu_din;
    reg         nmi_n = 1'b1;
    reg         irq = 1'b0;

    hd6309i cpu (
        .D(cpu_din), .DOut(cpu_dout), .ADDR(cpu_addr), .RnW(cpu_rw),
        .E(cpu_e), .Q(cpu_q), .BS(), .BA(),
        .nIRQ(~irq), .nFIRQ(1'b1), .nNMI(nmi_n),
        .AVMA(), .BUSY(), .LIC(cpu_lic),
        .nRESET(~rst), .nDMABREQ(1'b1), .nHALT(1'b1)
    );

    // ------------------------------------------------------------------ address decode
    wire wr_cyc   = e_end && !cpu_rw;                  // a write cycle just ended
    wire a_ram    = cpu_addr < 16'h1800;
    wire a_fix    = cpu_addr[15:11] == 5'b00011;       // 1800-1FFF
    wire a_bg     = cpu_addr[15:11] == 5'b00100;       // 2000-27FF
    wire a_pal    = cpu_addr[15:10] == 6'b001010;      // 2800-2BFF
    wire a_pale   = cpu_addr[15:10] == 6'b001011;      // 2C00-2FFF
    wire a_spr2   = cpu_addr[15:11] == 5'b00110;       // 3000-37FF
    wire a_rombk  = cpu_addr[15:14] == 2'b01;
    wire a_romfx  = cpu_addr[15];

    // ------------------------------------------------------------------ registers written by the CPU
    reg [7:0] ctrl = 8'h00;                            // 3830: bit0 SECCLR, bit1 NMI enable, bit3 flip, bits 4-7 ROM bank
    reg [7:0] scr_x_lo = 0, scr_y_lo = 0, r3828 = 0;
    reg [7:0] value_hi = 0, value_lo = 0, ret_hi = 0, ret_lo = 0;
    reg       int1_tog = 0, int1_tog_d = 0, irqclr_tog = 0, irqclr_tog_d = 0;
    reg [11:0] int1_cnt = 0;
    reg [7:0] p2_d = 8'hff;
    reg       nmi_en = 0, nmi_en_new = 0;
    reg [1:0] nmi_delay = 0;
    reg       prev_lic = 0;
    wire      cpu_lic;
    assign flip_screen = ctrl[3];

    // ------------------------------------------------------------------ RAMs
    // work RAM
    assign nv_cpu_we = wr_cyc && a_ram;
    assign nv_cpu_addr = cpu_addr[12:0];
    assign nv_cpu_data = cpu_dout;
    // Every reset clears the work RAM, like a power cycle. The real board keeps its RAM through a reset, but then the game takes its WARM start (it finds its own
    // data intact and skips its cold start initialisation): after an OSD reset in the middle of the music the sound chips were reset, the game believed the music was
    // still playing and never sent it again. Clearing the RAM makes the game start from scratch. The sweep needs 6144 clocks; the reset lasts at least 100 ms.
    reg [12:0] clr_a = 13'd0;
    always @(posedge clk) clr_a <= rst ? ((clr_a == 13'd6144) ? clr_a : clr_a + 1'd1) : 13'd0;
    wire clr_we = rst && (clr_a < 13'd6144);
    reg [7:0] wram [0:6143];
    reg [7:0] wram_q;
    always @(posedge clk) begin
        if (clr_we)                wram[clr_a] <= 8'h00;                 // power down style reset: the work RAM is cleared (see clr_a)
        else if (wr_cyc && a_ram)  wram[cpu_addr[12:0]] <= cpu_dout;
        else if (nv_inj_we)        wram[nv_inj_addr] <= nv_inj_data;
        wram_q <= wram[cpu_addr[12:0]];
    end

    // video RAMs: the CPU sees bytes, the video block reads words (even address = high byte)
    wire [9:0] fix_addr, bg_addr, spr_addr, pal_addr;
    wire [15:0] fix_q, bg_q, spr_q;
    wire [15:0] pal_q;
    wire [7:0] fixh_cq, fixl_cq, bgh_cq, bgl_cq, pall_cq, pale_cq, sprh_cq, sprl_cq;
    gondo_dpram #(10) u_fixh (.clk(clk), .we(wr_cyc && a_fix && !cpu_addr[0]), .wa(cpu_addr[10:1]), .wd(cpu_dout), .ra1(cpu_addr[10:1]), .rq1(fixh_cq), .ra2(fix_addr), .rq2(fix_q[15:8]));
    gondo_dpram #(10) u_fixl (.clk(clk), .we(wr_cyc && a_fix &&  cpu_addr[0]), .wa(cpu_addr[10:1]), .wd(cpu_dout), .ra1(cpu_addr[10:1]), .rq1(fixl_cq), .ra2(fix_addr), .rq2(fix_q[7:0]));
    gondo_dpram #(10) u_bgh  (.clk(clk), .we(wr_cyc && a_bg  && !cpu_addr[0]), .wa(cpu_addr[10:1]), .wd(cpu_dout), .ra1(cpu_addr[10:1]), .rq1(bgh_cq),  .ra2(bg_addr),  .rq2(bg_q[15:8]));
    gondo_dpram #(10) u_bgl  (.clk(clk), .we(wr_cyc && a_bg  &&  cpu_addr[0]), .wa(cpu_addr[10:1]), .wd(cpu_dout), .ra1(cpu_addr[10:1]), .rq1(bgl_cq),  .ra2(bg_addr),  .rq2(bg_q[7:0]));
    gondo_dpram #(10) u_pall (.clk(clk), .we(wr_cyc && a_pal),                 .wa(cpu_addr[9:0]),  .wd(cpu_dout), .ra1(cpu_addr[9:0]),  .rq1(pall_cq), .ra2(pal_addr), .rq2(pal_q[7:0]));
    gondo_dpram #(10) u_pale (.clk(clk), .we(wr_cyc && a_pale),                .wa(cpu_addr[9:0]),  .wd(cpu_dout), .ra1(cpu_addr[9:0]),  .rq1(pale_cq), .ra2(pal_addr), .rq2(pal_q[15:8]));

    // sprite RAM, and the copy of it the video block draws from (taken on the rising edge of 3828 bit 2)
    wire [9:0] cp_ra;                                  // copy engine read address
    wire [7:0] cp_h, cp_l;
    reg        cp_run = 0;
    reg [10:0] cp_cnt = 0;
    reg        vbl_start_d = 1'b0;
    wire       cp_wv = cp_run && cp_cnt != 0;                 // the RAM read data is one clock late: at count c it holds address c-1
    wire [9:0] cp_wa = cp_cnt[9:0] - 1'd1;
    gondo_dpram #(10) u_sprh (.clk(clk), .we(wr_cyc && a_spr2 && !cpu_addr[0]), .wa(cpu_addr[10:1]), .wd(cpu_dout), .ra1(cpu_addr[10:1]), .rq1(sprh_cq), .ra2(cp_ra), .rq2(cp_h));
    gondo_dpram #(10) u_sprl (.clk(clk), .we(wr_cyc && a_spr2 &&  cpu_addr[0]), .wa(cpu_addr[10:1]), .wd(cpu_dout), .ra1(cpu_addr[10:1]), .rq1(sprl_cq), .ra2(cp_ra), .rq2(cp_l));
    assign cp_ra = cp_cnt[9:0];
    wire [7:0] unused_h, unused_l;
    gondo_dpram #(10) u_bufh (.clk(clk), .we(cp_wv), .wa(cp_wa), .wd(cp_h), .ra1(10'd0), .rq1(unused_h), .ra2(spr_addr), .rq2(spr_q[15:8]));
    gondo_dpram #(10) u_bufl (.clk(clk), .we(cp_wv), .wa(cp_wa), .wd(cp_l), .ra1(10'd0), .rq1(unused_l), .ra2(spr_addr), .rq2(spr_q[7:0]));
    always @(posedge clk) begin
        if (cp_run) begin
            cp_cnt <= cp_cnt + 1'd1;
            if (cp_cnt == 11'd1024) cp_run <= 1'b0;
        end
        if (rst) begin cp_run <= 1'b0; cp_cnt <= 0; end
`ifdef SPR_COPY_AT_VBL
        else if (vbl_start && !vbl_start_d) begin cp_run <= 1'b1; cp_cnt <= 0; end      // experiment: copy at the rising edge of vblank instead
`else
        else if (wr_cyc && cpu_addr == 16'h3828 && !r3828[2] && cpu_dout[2]) begin cp_run <= 1'b1; cp_cnt <= 0; end
`endif
        vbl_start_d <= vbl_start;
    end

    // program ROM
    reg [7:0] rom [0:294911];
    reg [7:0] rom_q;
    wire [18:0] rom_ra = a_romfx ? {4'b1000, cpu_addr[14:0]} : {1'b0, ctrl[7:4], cpu_addr[13:0]};   // 0x40000 + offset, or bank * 16 KB + offset
    always @(posedge clk) begin
        if (mrom_we) rom[mrom_wa] <= mrom_wd;
        rom_q <= rom[rom_ra];
    end

    // character ROM, three planes of 8192 row bytes
    reg [7:0] cp0 [0:8191], cp1 [0:8191], cp2 [0:8191];
    wire [12:0] char_row_addr;
    reg  [23:0] char_row_q;
    always @(posedge clk) begin
        if (crom_we && crom_wa[14:13] == 2'd3) cp0[crom_wa[12:0]] <= crom_wd;
        if (crom_we && crom_wa[14:13] == 2'd2) cp1[crom_wa[12:0]] <= crom_wd;
        if (crom_we && crom_wa[14:13] == 2'd1) cp2[crom_wa[12:0]] <= crom_wd;
        char_row_q <= {cp0[char_row_addr], cp1[char_row_addr], cp2[char_row_addr]};
    end

    // ------------------------------------------------------------------ reads
    always @(*) begin
        if (a_romfx || a_rombk)                   cpu_din = rom_q;
        else if (a_ram)                           cpu_din = wram_q;
        else if (a_fix)                           cpu_din = cpu_addr[0] ? fixl_cq : fixh_cq;
        else if (a_bg)                            cpu_din = cpu_addr[0] ? bgl_cq : bgh_cq;
        else if (a_pal)                           cpu_din = pall_cq;
        else if (a_pale)                          cpu_din = pale_cq;
        else if (a_spr2)                          cpu_din = cpu_addr[0] ? sprl_cq : sprh_cq;
        else case (cpu_addr)
            16'h3800: cpu_din = io_3800;
            16'h3801: cpu_din = io_3801;
            16'h380A: cpu_din = io_380a;
            16'h380B: cpu_din = io_380b;
            16'h380C: cpu_din = io_380c;
            16'h380D: cpu_din = io_380d;
            16'h380E: cpu_din = {vbl_cpu, io_380e[6:0]};    // bit 7 = vblank
            16'h380F: cpu_din = io_380f;
            16'h3838: cpu_din = ret_hi;                     // i8751 reply, high byte
            16'h3839: cpu_din = ret_lo;                     // i8751 reply, low byte
            default:  cpu_din = 8'hff;
        endcase
    end

    // ------------------------------------------------------------------ NMI (vblank AND enable; MAME applies a new enable one opcode late)
    always @(posedge clk) if (cen12) nmi_n <= ~(vbl_cpu & nmi_en);

    // opcode starts: the cycle that just ended was an opcode fetch (LIC is high during it)
    // (the enable written to 3830 bit 1 takes effect after the next two opcode fetches, as measured against MAME)
    // ------------------------------------------------------------------ i8751 mailbox glue
    // The main CPU writes a 16 bit value (383A high, 383B low); the write to 383A pulses MCU INT1 for 4 clocks of 1.5 MHz.
    // The MCU reads the two bytes through latches enabled by P2.4 (high) and P2.5 (low), and answers by writing P0 and P1 and
    // dropping P2.6 (reply high) and P2.7 (reply low). A rising P2.2 raises the main CPU IRQ while SECCLR (3830 bit 0) is set.
    always @(posedge clk) if (cen12) begin
        int1_tog_d <= int1_tog; irqclr_tog_d <= irqclr_tog;
        if (int1_tog != int1_tog_d) int1_cnt <= `INT1_W;         // 4 clocks of 1.5 MHz = 32 periods of 12 MHz
        else if (int1_cnt != 0) int1_cnt <= int1_cnt - 1'd1;
        p2_d <= mcu_p2_o;
        if (p2_d[6] & ~mcu_p2_o[6]) ret_hi <= mcu_p0_o;
        if (p2_d[7] & ~mcu_p2_o[7]) ret_lo <= mcu_p1_o;
        if (~p2_d[2] & mcu_p2_o[2] & ctrl[0]) irq <= 1'b1;
        else if (irqclr_tog != irqclr_tog_d) irq <= 1'b0;
    end
    assign mcu_p0_i  = mcu_p2_o[4] ? 8'hff : value_hi;
    assign mcu_p1_i  = mcu_p2_o[5] ? 8'hff : value_lo;
    assign mcu_p2_i  = 8'hff;
    assign mcu_p3_i  = coin_p3;                                  // coin and service inputs
    assign mcu_int1n = (int1_cnt == 0);
    assign mcu_int0n = ~vbl_cpu;                                 // INT0 follows vblank

    // ------------------------------------------------------------------ CPU writes to the registers; the opcode-start bookkeeping
    always @(posedge clk) begin
        if (rst) begin
            ctrl <= 8'h00; r3828 <= 0; nmi_en <= 0; nmi_en_new <= 0; nmi_delay <= 0; prev_lic <= 0;
        end else if (e_end) begin
            if (!cpu_rw) begin
                if (cpu_addr == 16'h383B) value_lo <= cpu_dout;
                else if (cpu_addr == 16'h3818) scr_x_lo <= cpu_dout;
                else if (cpu_addr == 16'h3820) scr_y_lo <= cpu_dout;
                else if (cpu_addr == 16'h3828) r3828 <= cpu_dout;
                else if (cpu_addr == 16'h3810) begin snd_cmd <= cpu_dout; snd_cmd_tog <= ~snd_cmd_tog; end
                else if (cpu_addr == 16'h383A) begin value_hi <= cpu_dout; int1_tog <= ~int1_tog; end
                else if (cpu_addr == 16'h3830) begin
                    ctrl <= cpu_dout;
                    if (!cpu_dout[0]) irqclr_tog <= ~irqclr_tog;
                    if (cpu_dout[1] != ctrl[1]) begin nmi_en_new <= cpu_dout[1]; nmi_delay <= 2'd2; end
                end
            end
            if (prev_lic) begin   // the cycle that just ended was an opcode fetch: an instruction starts here
                if (nmi_delay != 0) begin
                    nmi_delay <= nmi_delay - 1'd1;
                    if (nmi_delay == 2'd1) nmi_en <= nmi_en_new;
                end
            end
            prev_lic <= cpu_lic;
        end
    end

    // ------------------------------------------------------------------ video
    gondo_video #(.INIT_H(INIT_H), .INIT_V(INIT_V)) u_video (
        .clk(clk), .rst(rst), .pxl_cen(pxl_cen),
        .scrx({r3828[0], scr_x_lo}), .scry({r3828[1], scr_y_lo}),
        .hs_start(hs_start), .hs_end(hs_end), .vs_start(vs_start), .vs_end(vs_end),
        .fix_addr(fix_addr), .fix_q(fix_q), .bg_addr(bg_addr), .bg_q(bg_q), .spr_addr(spr_addr), .spr_q(spr_q),
        .pal_addr(pal_addr), .pal_q(pal_q),
        .char_row_addr(char_row_addr), .char_row_q(char_row_q),
        .tile_row_addr(tile_row_addr), .tile_row_q(tile_row_q), .tile_ok(tile_ok),
        .spr_row_addr(spr_row_addr), .spr_row_q(spr_row_q), .spr_ok(spr_ok),
        .r(r), .g(g), .b(b), .hs(hs), .vs(vs), .hblank(hblank), .vblank(vblank), .de(de), .vbl_start(vbl_start), .vbl_cpu(vbl_cpu)
    );
endmodule

// Simple dual port RAM: port 1 is written and read (for the CPU), port 2 is read only (for the video block); both reads are registered.
module gondo_dpram #(parameter AW = 10) (
    input             clk,
    input             we,
    input  [AW-1:0]   wa,
    input  [7:0]      wd,
    input  [AW-1:0]   ra1,
    output reg [7:0]  rq1,
    input  [AW-1:0]   ra2,
    output reg [7:0]  rq2
);
    reg [7:0] mem [0:(1 << AW) - 1];
    always @(posedge clk) begin
        if (we) mem[wa] <= wd;
        rq1 <= mem[ra1];
        rq2 <= mem[ra2];
    end
endmodule
