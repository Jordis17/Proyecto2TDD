// =====================================================================
// display_controller.sv - Multiplexado de los displays de 7 segmentos
// =====================================================================

module display_controller #(
    parameter logic SEG_ACTIVE_LEVEL = 1'b0,   // 0 = segmento enciende con nivel bajo
    parameter logic AN_ACTIVE_LEVEL  = 1'b0    // 0 = digito habilita con nivel bajo
) (
    input  logic       clk_i,
    input  logic       rst_i,
    input  logic       tick_i,       // pulso de 1 ms
    input  logic [6:0] time_s_i,     // segundos restantes
    input  logic [7:0] wins_bcd_i,   // victorias en BCD, dos digitos
    output logic [6:0] seg_o,        // {g,f,e,d,c,b,a}
    output logic [7:0] an_o
);

    logic [1:0] dig_q = 2'd0;
    logic [3:0] t_dec, t_uni, nibble;
    logic [6:0] seg;
    logic [7:0] an;

    // ---- contador de digito ----
    always_ff @(posedge clk_i) begin
        if (rst_i)       dig_q <= 2'd0;
        else if (tick_i) dig_q <= dig_q + 2'd1;
    end
