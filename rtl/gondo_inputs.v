// ---------------------------------------------------------------------------------------------------------------------
// Gondomania for MiSTer - Copyright (C) 2026 Eggsecutioner528
// Licensed under the GNU General Public License, version 2 or (at your option) any later version (see LICENSE).
// Any copy or derived work must keep this notice, name the author and be published with its complete source under the same license.
// Provenance mark GDM-70ccedb2ef80
// ---------------------------------------------------------------------------------------------------------------------
// Gondomania player inputs as the main CPU and the i8751 read them (MAME ghostb.cpp gondo_state, local MAME 0.266 port list):
//   380A / 380C : ~(one-hot of the rotary position)[7:0]        (player 1 / player 2)
//   380B / 380D : {~(one-hot)[11:8], right, left, down, up}      (joystick bits active low)
//   380E        : bit 0 start 1, bit 1 start 2 (active low), bit 7 = vblank (added by gondo_main)
//   380F        : bit 0 P1 button 1, bit 1 P1 button 2, bit 2 P2 button 1, bit 3 P2 button 2
//   i8751 port 3: bit 4 service, bit 5 coin 1, bit 6 coin 2, bit 7 coin 3
// The rotary controller has 12 positions; MAME starts it at position 11. Here two buttons (Turn Left / Turn Right) step it, one step when pressed
// and again every REPEAT frames after a short delay while held, wrapping around. Turn Left steps the position up and Turn Right down (MAME defines
// this control with reverse="yes"; on the real hardware test the two directions were found swapped with the other assignment).
module gondo_inputs (
    input             clk,
    input             rst,
    input             frame_tick,                // once per frame
    input      [15:0] joy1, joy2,                // MiSTer: 0 right, 1 left, 2 down, 3 up, 4 button 1, 5 button 2, 6 turn left, 7 turn right, 8 start, 9 coin
    input             service,                   // active high
    output     [7:0]  io_380a, io_380b, io_380c, io_380d, io_380e, io_380f,
    output     [7:0]  coin_p3
);
    reg [3:0] pos1 = 4'd11, pos2 = 4'd11;
    reg       tl1 = 0, tr1 = 0, tl2 = 0, tr2 = 0;       // previous button state
    reg [4:0] hold1 = 0, hold2 = 0;                     // frames the current turn button has been held
    function [3:0] step(input [3:0] p, input up);
        step = up ? (p == 4'd11 ? 4'd0 : p + 4'd1) : (p == 4'd0 ? 4'd11 : p - 4'd1);
    endfunction
    localparam [4:0] DELAY = 5'd16, REPEAT = 5'd4;      // first repeat after 16 frames, then one step every 4 frames
    wire held1 = joy1[6] ^ joy1[7], held2 = joy2[6] ^ joy2[7];
    always @(posedge clk) begin
        tl1 <= joy1[6]; tr1 <= joy1[7]; tl2 <= joy2[6]; tr2 <= joy2[7];
        if (rst) begin pos1 <= 4'd11; pos2 <= 4'd11; hold1 <= 0; hold2 <= 0; end
        else begin
            if (held1 && ((joy1[6] & ~tl1) | (joy1[7] & ~tr1))) begin pos1 <= step(pos1, joy1[6]); hold1 <= 0; end
            else if (!held1) hold1 <= 0;
            else if (frame_tick) begin
                if (hold1 == DELAY) begin pos1 <= step(pos1, joy1[6]); hold1 <= DELAY - REPEAT; end else hold1 <= hold1 + 1'd1;
            end
            if (held2 && ((joy2[6] & ~tl2) | (joy2[7] & ~tr2))) begin pos2 <= step(pos2, joy2[6]); hold2 <= 0; end
            else if (!held2) hold2 <= 0;
            else if (frame_tick) begin
                if (hold2 == DELAY) begin pos2 <= step(pos2, joy2[6]); hold2 <= DELAY - REPEAT; end else hold2 <= hold2 + 1'd1;
            end
        end
    end
    wire [11:0] v1 = 12'd1 << pos1, v2 = 12'd1 << pos2;
    assign io_380a = ~v1[7:0];
    assign io_380b = {~v1[11:8], ~joy1[0], ~joy1[1], ~joy1[2], ~joy1[3]};     // bit 3 right, bit 2 left, bit 1 down, bit 0 up
    assign io_380c = ~v2[7:0];
    assign io_380d = {~v2[11:8], ~joy2[0], ~joy2[1], ~joy2[2], ~joy2[3]};
    assign io_380e = {1'b1, 5'b11111, ~joy2[8], ~joy1[8]};                   // bit 7 is replaced by the vblank flag in gondo_main
    assign io_380f = {4'b1111, ~joy2[5], ~joy2[4], ~joy1[5], ~joy1[4]};
    assign coin_p3 = {1'b1, ~joy2[9], ~joy1[9], ~service, 4'b1111};          // coin 3 not used
endmodule
