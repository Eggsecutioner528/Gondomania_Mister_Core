// High score persistence for Gondomania: restore after boot, save and clear on OSD buttons.
//
// The real board has no battery RAM; this is a convenience on top (same idea and the same structure as the Battlantis core, adapted to this game).
// The BEST 10 PLAYERS table is 72 bytes in the main CPU work RAM: ten 3 byte names (ASCII minus 0x20) then ten 4 byte big endian BCD scores (first byte
// always 00) and 2 spare bytes, at 0x14F9 for World and Japan, at 0x1532 for US (found and checked by simulation against the ROM code, see docs/PROJECT_NOTES.md).
// The game writes its factory table at EVERY boot (a zero clear about 236 ms after reset, the real table 14.5 ms later), so a saved table cannot be loaded at
// download time. The scheme:
//   1. hs_ram follows every write that reaches the table cells (the game's own and the restore below);
//   2. the file the HPS loads (nvram index 1, 216 bytes = one 72 byte slot per version, slot v at v * 72) is kept in hs_sav;
//   3. after a boot the table writes are watched; when they have stopped for 50 ms (HS_Q50) the table in the game is checked for the structure of a real table,
//      kept as the factory table (hs_fac, for Clear), and the saved slot of this version, if it passes the same check, is written into the work RAM through a
//      write port that the CPU does not use at that moment (inj_*), once per boot;
//   4. the OSD button Save copies the live table into the slot of the running version of hs_sav and asks the HPS to save the file; Clear copies the factory
//      table into the slot, writes it into the game and saves the file. Nothing is saved by itself, and never before the boot is over.
// A saved slot that is blank or does not look like a table (a new or foreign file) is never written into the game. The three 256 byte arrays are plain
// logic (MLAB, asynchronous read), no block RAM.
module gondo_nvram (
    input             clk,
    input             reset,              // the core's reset (held during downloads, the version copy and while the PLL is not locked)
    input      [1:0]  ver,                // running version: 0 US, 1 World, 2 Japan (3 is not valid, nothing is done); slot v of the file is v * 72
    // the CPU's writes to the work RAM (one clock pulse per write cycle) and the write port the restore uses when the CPU does not write
    input             cpu_we,
    input      [12:0] cpu_addr,
    input      [7:0]  cpu_data,
    output            inj_we,
    output     [12:0] inj_addr,
    output     [7:0]  inj_data,
    // HPS file I/O (hps_io)
    input             ioctl_download, ioctl_wr, ioctl_upload,
    input      [15:0] ioctl_index,
    input      [26:0] ioctl_addr,
    input      [7:0]  ioctl_dout,
    output     [7:0]  ioctl_din,
    output reg        upload_req,
    // OSD
    input             save_btn,           // trigger, 1 while pressed
    input             clear_yes,          // trigger, 1 while pressed
    output            ready               // the boot initialisation is over (and the saved table, if any, is in)
);
    localparam [12:0] BASE_US = 13'h1532, BASE_WJ = 13'h14F9;
    localparam [27:0] HS_Q50  = 28'd2_400_000;            // 50 ms at 48 MHz
    localparam [6:0]  LAST    = 7'd71;

    wire        vok   = (ver != 2'd3);
    wire [12:0] base  = (ver == 2'd0) ? BASE_US : BASE_WJ;
    wire [7:0]  sbase = (ver == 2'd1) ? 8'd72 : (ver == 2'd2) ? 8'd144 : 8'd0;

    (* ramstyle = "MLAB, no_rw_check" *) reg [7:0] hs_ram [0:127];   // live shadow of the table in the game (index 0 to 71)
    (* ramstyle = "MLAB, no_rw_check" *) reg [7:0] hs_fac [0:127];   // the factory table the game wrote at boot
    (* ramstyle = "MLAB, no_rw_check" *) reg [7:0] hs_sav [0:255];   // the NVRAM file: 3 slots of 72 bytes

    localparam [2:0] S_IDLE = 3'd0, S_CHKL = 3'd1, S_CAP = 3'd2, S_CHKS = 3'd3, S_INJ = 3'd4, S_READY = 3'd5, S_SAVE = 3'd6, S_CLR = 3'd7;
    reg [2:0]  st = S_IDLE;
    reg [6:0]  i = 7'd0;
    reg [27:0] quiet = 28'd0;
    reg        armed = 1'b0;          // the game wrote the table since the last check
    reg        fac_valid = 1'b0, clr_pend = 1'b0, bad = 1'b0, nz = 1'b0;
    reg        btn_q = 1'b0, clr_q = 1'b0;

    // ---- the write the restore makes (only on a clock where the CPU does not write the work RAM)
    wire        inj_on = (st == S_INJ);
    assign inj_we   = inj_on && !cpu_we;
    assign inj_addr = base + {6'd0, i};
    assign inj_data = hs_sav[sbase + {1'b0, i}];

    // ---- shadow of the table in the game: every write that reaches the table cells
    wire        w_any  = cpu_we | inj_we;
    wire [12:0] w_addr = cpu_we ? cpu_addr : inj_addr;
    wire [7:0]  w_data = cpu_we ? cpu_data : inj_data;
    wire [12:0] w_off  = w_addr - base;
    wire        w_hit  = w_any && vok && (w_addr >= base) && (w_off < 13'd72);

    // ---- the file
    wire        nv_idx = (ioctl_index[7:0] == 8'd1);
    wire        nv_wr  = ioctl_wr && ioctl_download && nv_idx && (ioctl_addr < 27'd256);
    assign ioctl_din = (ioctl_upload && nv_idx) ? hs_sav[ioctl_addr[7:0]] : 8'h00;

    // ---- structure check of one table byte (index i of the table, value d); the table is real if every byte passes and the top score is not zero
    //      names (0 to 29): 0x00 to 0x5F; scores (30 to 69): byte 0 of each entry 00, the other three BCD digits pairs; the 2 spare bytes are not checked
    wire [7:0] d      = (st == S_CHKL) ? hs_ram[i] : hs_sav[sbase + {1'b0, i}];
    wire       d_bcd  = (d[7:4] <= 4'd9) && (d[3:0] <= 4'd9);
    wire       d_ok   = (i < 7'd30) ? (d <= 8'h5F) : (i < 7'd70) ? ((i[1:0] == 2'd2) ? (d == 8'h00) : d_bcd) : 1'b1;
    wire       d_top  = (i >= 7'd31) && (i <= 7'd33) && (d != 8'h00);   // the top score has a non zero byte

    // hs_sav: the file from the HPS, a copy of the live table (Save) or of the factory table (Clear)
    wire       sav_cp  = (st == S_SAVE) || (st == S_CLR);
    wire       sav_we  = nv_wr | sav_cp;
    wire [7:0] sav_wa  = nv_wr ? ioctl_addr[7:0] : (sbase + {1'b0, i});
    wire [7:0] sav_wd  = nv_wr ? ioctl_dout : (st == S_CLR) ? hs_fac[i] : hs_ram[i];
    always @(posedge clk) begin
        if (w_hit) hs_ram[w_off[6:0]] <= w_data;
        if (sav_we) hs_sav[sav_wa] <= sav_wd;
        if (st == S_CAP) hs_fac[i] <= hs_ram[i];
    end

    assign ready = (st == S_READY);

    always @(posedge clk) begin
        btn_q <= save_btn;
        clr_q <= clear_yes;
        upload_req <= 1'b0;
        if (reset) begin
            st <= S_IDLE; i <= 7'd0; quiet <= 28'd0; armed <= 1'b0; fac_valid <= 1'b0; clr_pend <= 1'b0;
        end else begin
            // time since the game last wrote the table
            if (cpu_we && w_hit) begin armed <= 1'b1; quiet <= 28'd0; end
            else if (quiet != 28'hFFFFFFF) quiet <= quiet + 1'd1;

            case (st)
                S_IDLE: if (vok && armed && quiet >= HS_Q50) begin st <= S_CHKL; i <= 7'd0; bad <= 1'b0; nz <= 1'b0; armed <= 1'b0; end
                S_CHKL: begin                                        // is the table in the game a real one?
                    if (!d_ok) bad <= 1'b1;
                    if (d_top) nz <= 1'b1;
                    if (i == LAST) begin
                        if (!bad && d_ok && (nz || d_top)) begin st <= S_CAP; i <= 7'd0; end
                        else st <= S_IDLE;                           // RAM test pattern or the zero clear: wait for the next quiet period
                    end else i <= i + 1'd1;
                end
                S_CAP: if (i == LAST) begin fac_valid <= 1'b1; st <= S_CHKS; i <= 7'd0; bad <= 1'b0; nz <= 1'b0; end else i <= i + 1'd1;
                S_CHKS: begin                                        // is the saved slot of this version a real table?
                    if (!d_ok) bad <= 1'b1;
                    if (d_top) nz <= 1'b1;
                    if (i == LAST) begin
                        if (!bad && d_ok && (nz || d_top)) begin st <= S_INJ; i <= 7'd0; end
                        else st <= S_READY;                          // no usable saved table: the factory table stays
                    end else i <= i + 1'd1;
                end
                S_INJ: if (inj_we) begin
                    if (i == LAST) begin st <= S_READY; i <= 7'd0; if (clr_pend) begin clr_pend <= 1'b0; upload_req <= 1'b1; end end
                    else i <= i + 1'd1;
                end
                S_SAVE: if (i == LAST) begin st <= S_READY; i <= 7'd0; upload_req <= 1'b1; end else i <= i + 1'd1;
                S_CLR:  if (i == LAST) begin st <= S_INJ; i <= 7'd0; clr_pend <= 1'b1; end else i <= i + 1'd1;
                S_READY: begin
                    if (save_btn && !btn_q && vok) begin st <= S_SAVE; i <= 7'd0; end
                    else if (clear_yes && !clr_q && fac_valid && vok) begin st <= S_CLR; i <= 7'd0; end
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
