// =====================================================================
// lfsr.sv - Generador pseudoaleatorio de 8 bits
//
// Polinomio:  x^8 + x^6 + x^5 + x^4 + 1     (taps 8, 6, 5, 4)
//
// Implementacion de Fibonacci con desplazamiento a la izquierda. El bit
// realimentado entra por la posicion 0:
//
//     lfsr_q <= { lfsr_q[6:0], lfsr_q[7]^lfsr_q[5]^lfsr_q[4]^lfsr_q[3] }
//
// Los taps 8, 6, 5, 4 corresponden a las posiciones 7, 5, 4 y 3 del
// registro, porque el bit que representa x^i vive en lfsr_q[i-1].
//
// El registro es de CORRIDA LIBRE: avanza en cada flanco desde que sale
// del reset, sin habilitacion. Quien lo usa captura su valor en el
// instante que le interesa. La variedad entre partidas no la aporta el
// generador sino el momento impredecible en que alguien pulsa el boton;
// en simulacion, en cambio, el comportamiento es completamente
// determinista porque el testbench decide el ciclo exacto de captura.
//
// El estado 0x00 es absorbente en cualquier LFSR con realimentacion XOR
// y no forma parte del ciclo. La semilla debe ser distinta de cero, y el
// testbench comprueba que ese estado nunca se alcanza.
// =====================================================================

module lfsr #(
    parameter logic [7:0] SEED = 8'h01
) (
    input  logic       clk_i,
    input  logic       rst_i,
    output logic [7:0] lfsr_o
);

    logic [7:0] lfsr_q = SEED;

    assign lfsr_o = lfsr_q;

    always_ff @(posedge clk_i) begin
        if (rst_i) lfsr_q <= SEED;
        else       lfsr_q <= {lfsr_q[6:0],
                              lfsr_q[7] ^ lfsr_q[5] ^ lfsr_q[4] ^ lfsr_q[3]};
    end

endmodule