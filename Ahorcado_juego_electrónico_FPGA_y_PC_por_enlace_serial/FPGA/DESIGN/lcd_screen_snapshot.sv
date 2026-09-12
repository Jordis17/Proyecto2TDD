// =====================================================================
// lcd_screen_snapshot.sv - Copia registrada de los datos de la partida
//
// Al llegar capture_i (un pulso de un ciclo) guarda una copia estable de
// la pantalla pedida y de los datos de la partida. El redibujado dura
// varios milisegundos; sin esta copia, un cambio a mitad de camino
// dejaria la mitad de arriba de la pantalla con datos viejos y la de
// abajo con datos nuevos.
//
// Este modulo no tiene entrada de reinicio, y es a proposito: en la
// version anterior estos registros tampoco se limpiaban al reiniciar.
// Su unico valor de arranque es el que declara cada senal, que en la
// FPGA lo fija el bitstream. Lo que si se reinicia es la maquina de
// estados que genera capture_i, y esa vive en lcd_screen_ctrl.
// =====================================================================

module lcd_screen_snapshot #(
    parameter int MAX_LEN = 12
) (
    input  logic        clk_i,
    input  logic        capture_i,     // pulso: aceptar una nueva orden

    input  logic [2:0]           screen_i,
    input  logic [8*MAX_LEN-1:0] word_data_i,
    input  logic [3:0]           word_len_i,
    input  logic [MAX_LEN-1:0]   revealed_i,
    input  logic [2:0]           errors_i,
    input  logic                 mode_i,
    input  logic [7:0]           wins_i,

    output logic [2:0]           scr_o,
    output logic [8*MAX_LEN-1:0] word_data_o,
    output logic [3:0]           word_len_o,
    output logic [MAX_LEN-1:0]   revealed_o,
    output logic [2:0]           errors_o,
    output logic                 mode_o,
    output logic [7:0]           wins_o
);

    logic [2:0]           scr_q  = '0;
    logic [8*MAX_LEN-1:0] wd_q   = '0;
    logic [3:0]           wl_q   = 4'd0;
    logic [MAX_LEN-1:0]   rev_q  = '0;
    logic [2:0]           err_q  = 3'd0;
    logic                 mode_q = 1'b0;
    logic [7:0]           wins_q = 8'h00;

    always_ff @(posedge clk_i) begin
        if (capture_i) begin
            scr_q  <= screen_i;
            wd_q   <= word_data_i;
            wl_q   <= word_len_i;
            rev_q  <= revealed_i;
            err_q  <= errors_i;
            mode_q <= mode_i;
            wins_q <= wins_i;
        end
    end

    assign scr_o       = scr_q;
    assign word_data_o = wd_q;
    assign word_len_o  = wl_q;
    assign revealed_o  = rev_q;
    assign errors_o    = err_q;
    assign mode_o      = mode_q;
    assign wins_o       = wins_q;

endmodule
