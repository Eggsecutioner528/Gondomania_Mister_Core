// ---------------------------------------------------------------------------------------------------------------------
// Gondomania for MiSTer - Copyright (C) 2026 Eggsecutioner528
// Licensed under the GNU General Public License, version 2 or (at your option) any later version (see LICENSE).
// Any copy or derived work must keep this notice, name the author and be published with its complete source under the same license.
// Provenance mark GDM-87e8598a9fc7
// ---------------------------------------------------------------------------------------------------------------------
// Gondomania sound board: R65C02 (1.5 MHz), YM2203 (1.5 MHz), YM3526 (3 MHz), after MAME's garyoret_state::gondo_sound_map:
//   0000-05FF RAM   2000-2001 YM2203 (write)   4000-4001 YM3526 (write)   6000 sound latch (read)   8000-FFFF ROM (32 KB)
// The main CPU's write to 3810 stores the command in the latch and gives the sound CPU an NMI that is released after 4 CPU cycles (MAME sound_w).
// Both chips' IRQ outputs are wired together to the CPU IRQ. The CPU core is Jose Tejada's jt65c02 (JTCORES, GPL-3), the chips jt03 / jtopl.
`ifndef NMI_W
`define NMI_W 8'd128
`endif
module gondo_sound (
    input             clk,                // 48 MHz
    input             rst,
    input      [7:0]  snd_cmd,
    input             snd_cmd_tog,
    input             rom_we,
    input      [14:0] rom_wa,
    input      [7:0]  rom_wd,
    // Sound Settings (OSD): volume index of the music (YM3526), the effects (YM2203 FM voices) and the whole mix, and the treble mode. Index 0 = 100 percent
    // = the original mix bit for bit; 1..3 boost (125, 150, 200 percent), 4..12 attenuate, 13 and up = off.
    input      [3:0]  vol_music, vol_fx, vol_master,
    input      [1:0]  treble,
    output signed [15:0] audio
);
    // clock enables: 6 MHz for the CPU core (it divides by 4 into the 1.5 MHz E clock), 1.5 MHz for the YM2203, 3 MHz for the YM3526
    reg [4:0] cdiv = 5'd0;
    always @(posedge clk) cdiv <= rst ? 5'd0 : cdiv + 1'd1;
    wire cen6   = (cdiv[2:0] == 3'd7);
    wire cen_opn = (cdiv == 5'd31);
    wire cen_opl = (cdiv[3:0] == 4'd15);

    wire [15:0] cpu_addr;
    wire  [7:0] cpu_dout;
    wire        cpu_wr, cpu_rd;
    reg   [7:0] cpu_din;
    wire        irq_n_opn, irq_n_opl;
    reg         nmi = 1'b0;
    reg   [7:0] nmi_cnt = 8'd0;
    reg         tog_d = 1'b0;

    // NMI: 4 CPU cycles (4 x 32 clocks of the 48 MHz clock) after every command write
    always @(posedge clk) begin
        tog_d <= snd_cmd_tog;
        if (rst) begin nmi <= 1'b0; nmi_cnt <= 8'd0; end
        else begin
            if (snd_cmd_tog != tog_d) begin nmi <= 1'b1; nmi_cnt <= `NMI_W; end
            else if (nmi_cnt != 0) begin nmi_cnt <= nmi_cnt - 1'd1; if (nmi_cnt == 8'd1) nmi <= 1'b0; end
        end
    end

    jt65c02 u_cpu (
        .rst(rst), .clk(clk), .cen(cen6),
        .irq(~(irq_n_opn & irq_n_opl)), .nmi(nmi),
        .wr(cpu_wr), .rd(cpu_rd), .addr(cpu_addr), .din(cpu_din), .dout(cpu_dout)
    );

    // chip selects, registered one clock after the access starts (as in jtcop_snd)
    wire cpu_acc = cpu_rd | cpu_wr;
    reg  ram_cs = 0, opn_cs = 0, opl_cs = 0, latch_cs = 0, rom_cs = 0;
    always @(posedge clk) begin
        ram_cs <= 0; opn_cs <= 0; opl_cs <= 0; latch_cs <= 0;
        if (rst) rom_cs <= 0;
        else if (cpu_acc) begin
            rom_cs <= cpu_addr[15];
            if (!cpu_addr[15]) begin
                if (cpu_addr < 16'h0600)                         ram_cs   <= 1;
                if (cpu_addr[15:1] == 15'h1000)                  opn_cs   <= 1;      // 2000-2001
                if (cpu_addr[15:1] == 15'h2000)                  opl_cs   <= 1;      // 4000-4001
                if (cpu_addr == 16'h6000)                        latch_cs <= 1;
            end
        end
    end

    // ROM 32 KB and RAM 2 KB (0600-07FF unused by the game), registered reads
    (* ramstyle = "M10K" *) reg [7:0] rom [0:32767];
    reg [7:0] rom_q;
    always @(posedge clk) begin
        if (rom_we) rom[rom_wa] <= rom_wd;
        rom_q <= rom[cpu_addr[14:0]];
    end
    (* ramstyle = "M10K" *) reg [7:0] ram [0:2047];
    // Power-up contents of the unused top of this RAM (the CPU only reaches 0000-05FF): the author's mark, see NOTICE.md. Written by tools/make_prov.py.
    // WM-BEGIN
    initial begin
        ram[1536] = 8'h62; ram[1537] = 8'h1a; ram[1538] = 8'h14; ram[1539] = 8'hfc; ram[1540] = 8'heb; ram[1541] = 8'h81; ram[1542] = 8'ha8; ram[1543] = 8'haf;
        ram[1544] = 8'hbb; ram[1545] = 8'hc3; ram[1546] = 8'h7d; ram[1547] = 8'h2c; ram[1548] = 8'hb9; ram[1549] = 8'h12; ram[1550] = 8'hb5; ram[1551] = 8'h81;
        ram[1552] = 8'hfa; ram[1553] = 8'h40; ram[1554] = 8'h31; ram[1555] = 8'h52; ram[1556] = 8'h86; ram[1557] = 8'h13; ram[1558] = 8'hfa; ram[1559] = 8'h5a;
        ram[1560] = 8'hfb; ram[1561] = 8'h7d; ram[1562] = 8'h56; ram[1563] = 8'h50; ram[1564] = 8'hb6; ram[1565] = 8'hf9; ram[1566] = 8'h7a; ram[1567] = 8'hd0;
        ram[1568] = 8'h40; ram[1569] = 8'ha6; ram[1570] = 8'h83; ram[1571] = 8'h64; ram[1572] = 8'hf2; ram[1573] = 8'h99; ram[1574] = 8'ha9; ram[1575] = 8'h5c;
        ram[1576] = 8'h81; ram[1577] = 8'hb1; ram[1578] = 8'h0f; ram[1579] = 8'ha3; ram[1580] = 8'he2; ram[1581] = 8'h0c; ram[1582] = 8'h2a; ram[1583] = 8'h63;
        ram[1584] = 8'h45; ram[1585] = 8'h83; ram[1586] = 8'h02; ram[1587] = 8'h6f; ram[1588] = 8'h4d; ram[1589] = 8'h3c; ram[1590] = 8'ha4; ram[1591] = 8'hce;
        ram[1592] = 8'h1b; ram[1593] = 8'hed; ram[1594] = 8'h51; ram[1595] = 8'h52; ram[1596] = 8'hc6; ram[1597] = 8'h4f; ram[1598] = 8'h85; ram[1599] = 8'he6;
        ram[1600] = 8'h8c; ram[1601] = 8'hf5; ram[1602] = 8'h33; ram[1603] = 8'hfa; ram[1604] = 8'hc3; ram[1605] = 8'hc9; ram[1606] = 8'hef; ram[1607] = 8'hc4;
        ram[1608] = 8'hb4; ram[1609] = 8'hc6; ram[1610] = 8'hf3; ram[1611] = 8'h05; ram[1612] = 8'hce; ram[1613] = 8'hf6; ram[1614] = 8'h9b; ram[1615] = 8'h88;
        ram[1616] = 8'h23; ram[1617] = 8'h51; ram[1618] = 8'h78; ram[1619] = 8'hdf; ram[1620] = 8'hb5; ram[1621] = 8'h53; ram[1622] = 8'h0a; ram[1623] = 8'h7f;
        ram[1624] = 8'h53; ram[1625] = 8'hd0; ram[1626] = 8'h2d; ram[1627] = 8'h64; ram[1628] = 8'h98; ram[1629] = 8'he2; ram[1630] = 8'ha9; ram[1631] = 8'h8a;
        ram[1632] = 8'h04; ram[1633] = 8'h9f; ram[1634] = 8'hea; ram[1635] = 8'hac; ram[1636] = 8'h23; ram[1637] = 8'h28; ram[1638] = 8'h52; ram[1639] = 8'h5b;
        ram[1640] = 8'ha4; ram[1641] = 8'h40; ram[1642] = 8'hc5; ram[1643] = 8'h0a; ram[1644] = 8'h35; ram[1645] = 8'hde; ram[1646] = 8'he6; ram[1647] = 8'h90;
        ram[1648] = 8'h50; ram[1649] = 8'hda; ram[1650] = 8'h68; ram[1651] = 8'h7e; ram[1652] = 8'hc4; ram[1653] = 8'h82; ram[1654] = 8'h7f; ram[1655] = 8'h41;
        ram[1656] = 8'h88; ram[1657] = 8'hd5; ram[1658] = 8'h3f; ram[1659] = 8'h1f; ram[1660] = 8'h0e; ram[1661] = 8'h3c; ram[1662] = 8'hd8; ram[1663] = 8'h0c;
        ram[1664] = 8'hc8; ram[1665] = 8'h12; ram[1666] = 8'hcb; ram[1667] = 8'hdf; ram[1668] = 8'he6; ram[1669] = 8'h65; ram[1670] = 8'h64; ram[1671] = 8'h76;
        ram[1672] = 8'h3f; ram[1673] = 8'h4b; ram[1674] = 8'h8d; ram[1675] = 8'h5f; ram[1676] = 8'h65; ram[1677] = 8'h79; ram[1678] = 8'hca; ram[1679] = 8'h71;
        ram[1680] = 8'h54; ram[1681] = 8'hd2; ram[1682] = 8'h6f; ram[1683] = 8'hbd; ram[1684] = 8'h44; ram[1685] = 8'h1d; ram[1686] = 8'h8c; ram[1687] = 8'hbd;
        ram[1688] = 8'h1b; ram[1689] = 8'h76; ram[1690] = 8'hfd; ram[1691] = 8'h66; ram[1692] = 8'h71; ram[1693] = 8'he2; ram[1694] = 8'h98; ram[1695] = 8'h97;
        ram[1696] = 8'h9a; ram[1697] = 8'h56; ram[1698] = 8'h34; ram[1699] = 8'hb5; ram[1700] = 8'hee; ram[1701] = 8'hda; ram[1702] = 8'h3e; ram[1703] = 8'hba;
        ram[1704] = 8'h06; ram[1705] = 8'hd2; ram[1706] = 8'hf5; ram[1707] = 8'hd5; ram[1708] = 8'hfe; ram[1709] = 8'hd7; ram[1710] = 8'h0d; ram[1711] = 8'haa;
        ram[1712] = 8'h48; ram[1713] = 8'h00; ram[1714] = 8'h61; ram[1715] = 8'h45; ram[1716] = 8'hf5; ram[1717] = 8'h22; ram[1718] = 8'h27; ram[1719] = 8'h55;
        ram[1720] = 8'h66; ram[1721] = 8'hbc; ram[1722] = 8'h19; ram[1723] = 8'h56; ram[1724] = 8'hd9; ram[1725] = 8'h4b; ram[1726] = 8'h76; ram[1727] = 8'h3c;
        ram[1728] = 8'h85; ram[1729] = 8'h49; ram[1730] = 8'h17; ram[1731] = 8'hfd; ram[1732] = 8'h0b; ram[1733] = 8'hc9; ram[1734] = 8'hf7; ram[1735] = 8'ha0;
        ram[1736] = 8'h58; ram[1737] = 8'h33; ram[1738] = 8'h02; ram[1739] = 8'h60; ram[1740] = 8'hcb; ram[1741] = 8'h9e; ram[1742] = 8'h3e; ram[1743] = 8'h11;
        ram[1744] = 8'h89; ram[1745] = 8'hf8; ram[1746] = 8'ha6; ram[1747] = 8'h6f; ram[1748] = 8'h20; ram[1749] = 8'h31; ram[1750] = 8'hfc; ram[1751] = 8'h26;
        ram[1752] = 8'h6c; ram[1753] = 8'hfe; ram[1754] = 8'h46; ram[1755] = 8'h73; ram[1756] = 8'hf0; ram[1757] = 8'h39; ram[1758] = 8'h8e; ram[1759] = 8'h79;
        ram[1760] = 8'h4b; ram[1761] = 8'ha6; ram[1762] = 8'hc0; ram[1763] = 8'h58; ram[1764] = 8'h8b; ram[1765] = 8'h0a; ram[1766] = 8'hf9; ram[1767] = 8'hfc;
        ram[1768] = 8'h3b; ram[1769] = 8'h64; ram[1770] = 8'h1e; ram[1771] = 8'h35; ram[1772] = 8'h4c; ram[1773] = 8'h14; ram[1774] = 8'h4d; ram[1775] = 8'h17;
        ram[1776] = 8'hc3; ram[1777] = 8'h4e; ram[1778] = 8'h2b; ram[1779] = 8'hc5; ram[1780] = 8'he5; ram[1781] = 8'hd1; ram[1782] = 8'he3; ram[1783] = 8'h6e;
        ram[1784] = 8'ha4; ram[1785] = 8'h44; ram[1786] = 8'h65; ram[1787] = 8'ha3; ram[1788] = 8'h8d; ram[1789] = 8'hef; ram[1790] = 8'h13; ram[1791] = 8'hff;
    end
    // WM-END
    reg [7:0] ram_q;
    wire ram_we = ram_cs & cpu_wr;
    always @(posedge clk) begin
        if (ram_we) ram[cpu_addr[10:0]] <= cpu_dout;
        ram_q <= ram[cpu_addr[10:0]];
    end

    always @(*) begin
        cpu_din = rom_cs   ? rom_q :
                  ram_cs   ? ram_q :
                  latch_cs ? snd_cmd :
                  8'hff;
    end

    wire signed [15:0] fm_snd, opl_snd;
    wire        [9:0]  psg_snd;
    wire        [7:0]  nc_opn, nc_opl;
    jt03 u_ym2203 (
        .rst(rst), .clk(clk), .cen(cen_opn),
        .din(cpu_dout), .addr(cpu_addr[0]), .cs_n(~opn_cs), .wr_n(~cpu_wr),
        .dout(nc_opn), .irq_n(irq_n_opn),
        .IOA_in(8'd0), .IOB_in(8'd0), .IOA_out(), .IOB_out(),
        .psg_A(), .psg_B(), .psg_C(),
        .fm_snd(fm_snd), .psg_snd(psg_snd), .snd(), .snd_sample()
    );
    jtopl u_ym3526 (
        .rst(rst), .clk(clk), .cen(cen_opl),
        .din(cpu_dout), .addr(cpu_addr[0]), .cs_n(~opl_cs), .wr_n(~cpu_wr),
        .dout(nc_opl), .irq_n(irq_n_opl), .snd(opl_snd), .sample(),
        .dbg_eg_V(), .dbg_ch0car_valid()
    );

    // Mix after MAME's routing: YM2203 FM 0.40, each SSG channel 0.20, YM3526 0.50. The gains (in 1/64) come from a fit against a MAME recording of the
    // attract mode (tools/fit_audio_gains.py, per band energies): FM 54, YM3526 29 (this core's YM3526 output is about 2.3 times louder than MAME's for the
    // same register writes). The attract mode has no SSG sound, so its gain follows from jt03's own chip level balance (its mix is fm + 32 * ssg sum)
    // with MAME's SSG : FM route ratio of 1 : 2, scaled like the FM gain: 54 * 32 / 2 / 64 = 13.5.
    // A replay of a MAME gameplay run (tools/mame_sndlog.lua, sim_core tb_snd) showed: the music is the YM3526, the sound effects are the YM2203 FM voices
    // (the SSG is never used by this game), and 54 / 29 reproduce MAME's balance. The effects are hard to hear next to the music, so on the user's request
    // the FM gain is raised by 1.6 (54 -> 86); the Sound Settings page can lower either chip again.
    localparam signed [7:0] G_FM = 8'sd86, G_OPL = 8'sd29;
    localparam        [7:0] G_PSG = 8'd13;
    // volume index -> gain in sixteenths (16 = 100 percent)
    function [5:0] gl(input [3:0] i);
        case (i)
            4'd0: gl = 6'd16;  4'd1: gl = 6'd20;  4'd2: gl = 6'd24;  4'd3: gl = 6'd32;
            4'd4: gl = 6'd14;  4'd5: gl = 6'd12;  4'd6: gl = 6'd10;  4'd7: gl = 6'd8;
            4'd8: gl = 6'd6;   4'd9: gl = 6'd4;   4'd10: gl = 6'd3;  4'd11: gl = 6'd2;
            4'd12: gl = 6'd1;  default: gl = 6'd0;
        endcase
    endfunction
    wire signed [6:0]  gf = $signed({1'b0, gl(vol_fx)});
    wire signed [6:0]  go = $signed({1'b0, gl(vol_music)});
    wire signed [6:0]  gm = $signed({1'b0, gl(vol_master)});
    wire signed [22:0] fm_p  = fm_snd  * gf;
    wire signed [22:0] opl_p = opl_snd * go;
    // The levels are static, so the chain is cut into register stages (the delay of a few 48 MHz clocks does not matter): level, mix, DC blocker, master, clip.
    reg  signed [17:0] fm_l = 18'sd0, opl_l = 18'sd0;                  // (x * 16) >>> 4 = x: index 0 leaves every source untouched
    reg  signed [19:0] mixs = 20'sd0;
    wire signed [27:0] mix = fm_l * G_FM + opl_l * G_OPL + $signed({1'b0, psg_snd}) * $signed({1'b0, G_PSG});   // wide: the sum must not be cut before the shift
    always @(posedge clk) begin
        fm_l  <= fm_p  >>> 4;
        opl_l <= opl_p >>> 4;
        mixs  <= mix >>> 6;
    end
    // DC blocker (the SSG output is unsigned and its own DC removal needs seconds to settle after power on; MAME's output is centred): one pole high
    // pass of about 4 Hz, updated at the 1.5 MHz enable
    reg signed [35:0] dc_acc = 36'sd0;
    wire signed [19:0] dc_lp = dc_acc >>> 16;
    always @(posedge clk) begin
        if (rst) dc_acc <= 36'sd0;
        else if (cen_opn) dc_acc <= dc_acc + mixs - dc_lp;
    end
    wire signed [20:0] outs = mixs - dc_lp;
    reg  signed [27:0] outm = 28'sd0;
    reg  signed [15:0] mono = 16'sd0;
    always @(posedge clk) begin
        outm <= (outs * gm) >>> 4;
        mono <= (outm > 28'sd32767) ? 16'sd32767 : (outm < -28'sd32768) ? -16'sd32768 : outm[15:0];
    end
    // Treble (OSD): Original passes the mix through untouched, Soft / Softer / Muffled run it through a one pole low pass (audio_lp.v, 3 MHz update)
    wire signed [15:0] lp_l, lp_r;
    audio_lp u_lp (.clk(clk), .ce(cen_opl), .mode(treble), .in_l(mono), .in_r(mono), .out_l(lp_l), .out_r(lp_r));
    assign audio = lp_l;
endmodule
