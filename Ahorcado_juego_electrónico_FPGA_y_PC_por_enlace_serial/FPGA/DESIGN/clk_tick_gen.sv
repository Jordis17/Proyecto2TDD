// =====================================================================
// clk_tick_gen.sv - Generador de pulsos (Base de tiempo del sistema)
//
// Genera un pulso de habilitacion de un ciclo cada TICK_CYCLES ciclos
// de reloj. Con el valor por defecto y un reloj de 100 MHz:
//
//     100 000 000 ciclos/s / 1000 ms/s = 100 000 ciclos por milisegundo
//
// De esta forma se obtiene un tick de 1 ms, que se utiliza como base
// de tiempo para el temporizador del juego.
// =====================================================================

module clk_tick_gen #(
    parameter int TICK_CYCLES = 100_000
) (
    input  logic clk_i,
    input  logic rst_i,
    output logic tick_o
);

    // Ancho necesario para contar hasta TICK_CYCLES-1.
    // Se usa al menos un bit para evitar un ancho nulo.
    localparam int W = (TICK_CYCLES <= 1) ? 1 : $clog2(TICK_CYCLES);

    logic [W-1:0] cnt_q = '0;

    // El tick se genera cuando el contador llega al valor limite.
    // Se deja como senal combinacional para usarlo directamente como
    // habilitacion en la logica sincrona.
    assign tick_o = (cnt_q == W'(TICK_CYCLES - 1));

    always_ff @(posedge clk_i) begin
        if (rst_i)       cnt_q <= '0;
        else if (tick_o) cnt_q <= '0;
        else             cnt_q <= cnt_q + 1'b1;
    end

endmodule

