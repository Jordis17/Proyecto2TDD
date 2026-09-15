// =====================================================================
// lcd_step_decoder.sv - Decodifica el numero de paso de la secuencia
//
// De los 34 pasos que arma una pantalla (2 comandos de direccion + 32
// caracteres, 16 por fila):
//   paso 0        comando de direccion de la fila 0
//   paso 1..16    caracteres de la fila 0
//   paso 17       comando de direccion de la fila 1
//   paso 18..33   caracteres de la fila 1
//
// Sobre el calculo de "col"
// --------------------------
// La columna es el numero de paso menos el del primer caracter de su
// fila. La resta se hace en 4 bits a proposito: para paso=16 (ultimo
// caracter de la fila 0), paso_i[3:0] vale 0 (16 mod 16 = 0), y al
// restar 1 en aritmetica de 4 bits sin signo el resultado da la vuelta
// (envolvimiento, "wraparound") a 15, que es justo la ultima columna.
// Lo mismo pasa en paso=33 de la fila 1. Es intencional: no hace falta
// un caso especial para el ultimo caracter de cada fila.
//
// Ese truco vale porque la pantalla tiene exactamente 16 columnas y 16
// es la capacidad de 4 bits. Con otro ancho de pantalla habria que
// rehacer la cuenta, asi que queda dicho aqui.
// =====================================================================

module lcd_step_decoder (
    input  logic [5:0] paso_i,
    output logic       es_comando_o,
    output logic       fila_o,
    output logic [3:0] col_o,
    output logic       es_ultimo_o
);

    // N_COL viene del paquete: es la misma constante que usa el generador
    // de texto, y repetirla aqui era justo lo que el paquete evita.
    import lcd_screen_pkg::N_COL;

    localparam int         N_PASOS   = 2 + 2*N_COL;           // 34
    localparam logic [5:0] PASO_FIL1 = 6'(1 + N_COL);         // 17
    localparam logic [5:0] ULT_PASO  = 6'(N_PASOS - 1);       // 33

    assign es_comando_o = (paso_i == 6'd0) || (paso_i == PASO_FIL1);
    assign fila_o       = (paso_i >= PASO_FIL1);

    // fila 0: paso 1 -> col 0 ... paso 16 -> col 15 (con wraparound)
    // fila 1: paso 18 -> col 0 ... paso 33 -> col 15 (con wraparound)
    assign col_o = fila_o ? (paso_i[3:0] - 4'd2)
                          : (paso_i[3:0] - 4'd1);

    assign es_ultimo_o = (paso_i == ULT_PASO);

endmodule
