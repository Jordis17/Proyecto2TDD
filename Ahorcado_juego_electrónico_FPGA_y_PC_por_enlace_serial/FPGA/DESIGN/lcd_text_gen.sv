// =====================================================================
// lcd_text_gen.sv - Generador de texto de cada pantalla del LCD
//
// Dado el codigo de pantalla, la fila y columna actuales (de
// lcd_step_decoder) y los datos de la partida (de lcd_screen_snapshot),
// arma el byte que corresponde a esa posicion: un comando de direccion
// si es el primer paso de una fila, o el caracter/instruccion que va en
// esa columna.
//
// Es puramente combinacional: no guarda estado propio, todo el estado
// vive en lcd_screen_snapshot y en el contador de paso de
// lcd_screen_ctrl.
// =====================================================================

module lcd_text_gen #(
    parameter int MAX_LEN = 12
) (
    input  logic [2:0]   scr_i,
    input  logic         fila_i,
    input  logic [3:0]   col_i,
    input  logic         es_comando_i,

    input  logic [8*MAX_LEN-1:0] word_data_i,   // primer caracter en los bits altos
    input  logic [3:0]           word_len_i,
    input  logic [MAX_LEN-1:0]   revealed_i,    // bit c en uno: posicion c revelada
    input  logic [2:0]           errors_i,      // errores cometidos, 0 a 6
    input  logic                 mode_i,        // 0 facil, 1 dificil
    input  logic [7:0]           wins_i,        // BCD de dos digitos

    output logic [7:0]   byte_o,
    output logic         rs_o
);

    import lcd_screen_pkg::SCR_SELECT, lcd_screen_pkg::SCR_PLAY,
           lcd_screen_pkg::SCR_WIN, lcd_screen_pkg::SCR_LOSE_FALLOS,
           lcd_screen_pkg::SCR_LOSE_TIEMPO, lcd_screen_pkg::N_COL;

    // Set DDRAM Address: fila 0 en 0x00 y fila 1 en 0x40.
    localparam logic [7:0] CMD_FILA0 = 8'h80;
    localparam logic [7:0] CMD_FILA1 = 8'hC0;

    localparam logic [7:0] CAR_ESPACIO = 8'h20;
    localparam logic [7:0] CAR_GUION   = 8'h5F;   // '_'
    localparam logic [7:0] CAR_CERO    = 8'h30;   // '0'
    localparam logic [7:0] CAR_D       = 8'h44;   // 'D' de dificil
    localparam logic [7:0] CAR_F       = 8'h46;   // 'F' de facil

    localparam logic [2:0] MAX_ERR = 3'd6;

    // textos fijos, un caracter por columna, el primero en los bits altos
    localparam logic [8*N_COL-1:0] LIN_FACIL   = "MODO: FACIL     ";
    localparam logic [8*N_COL-1:0] LIN_DIFICIL = "MODO: DIFICIL   ";
    localparam logic [8*N_COL-1:0] LIN_GANASTE = "   GANASTE!     ";
    localparam logic [8*N_COL-1:0] LIN_FALLOS  = "PERDISTE: FALLOS";
    localparam logic [8*N_COL-1:0] LIN_TIEMPO  = "PERDISTE: TIEMPO";

    // ---------------------------------------------------------------
    // Lineas con contenido variable
    // ---------------------------------------------------------------
    logic [2:0] intentos;
    logic [4:0] wl5;

    assign intentos = MAX_ERR - errors_i;   // hacia afuera se informa lo que queda
    assign wl5      = {1'b0, word_len_i};

    logic [8*N_COL-1:0] lin_titulo, lin_modo, lin_intentos;

    assign lin_titulo = {"AHORCADO  V:",
                         CAR_CERO + {4'b0000, wins_i[7:4]},
                         CAR_CERO + {4'b0000, wins_i[3:0]},
                         "  "};

    assign lin_modo = mode_i ? LIN_DIFICIL : LIN_FACIL;

    assign lin_intentos = {"INTENTOS: ",
                           CAR_CERO + {5'b00000, intentos},
                           "    ",
                           mode_i ? CAR_D : CAR_F};

    // El patron y la palabra se arman columna a columna, asi que se
    // guardan como vector de caracteres y no como una linea de texto.
    logic [7:0] patron  [0:N_COL-1];
    logic [7:0] palabra [0:N_COL-1];

    always_comb begin
        for (int c = 0; c < N_COL; c++) begin
            patron[c]  = CAR_ESPACIO;
            palabra[c] = CAR_ESPACIO;
        end
        for (int c = 0; c < MAX_LEN; c++) begin
            if (c < wl5) begin
                palabra[c] = word_data_i[8*(MAX_LEN-1-c) +: 8];
                patron[c]  = revealed_i[c] ? word_data_i[8*(MAX_LEN-1-c) +: 8] : CAR_GUION;
            end
        end
    end

    // ---------------------------------------------------------------
    // Caracter de la columna actual
    // ---------------------------------------------------------------
    logic [6:0] base;
    logic [7:0] car, byte_tx;
    logic       rs_tx;

    assign base = 7'd120 - {col_i, 3'b000};    // 8*(15 - col)

    always_comb begin
        unique case (scr_i)
            SCR_SELECT:      car = fila_i ? lin_modo[base +: 8] : lin_titulo[base +: 8];
            SCR_PLAY:        car = fila_i ? lin_intentos[base +: 8] : patron[col_i];
            SCR_WIN:         car = fila_i ? palabra[col_i] : LIN_GANASTE[base +: 8];
            SCR_LOSE_FALLOS: car = fila_i ? palabra[col_i] : LIN_FALLOS[base +: 8];
            SCR_LOSE_TIEMPO: car = fila_i ? palabra[col_i] : LIN_TIEMPO[base +: 8];
            default:         car = CAR_ESPACIO;
        endcase
    end

    assign byte_tx = es_comando_i ? (fila_i ? CMD_FILA1 : CMD_FILA0) : car;
    assign rs_tx   = !es_comando_i;

    assign byte_o = byte_tx;
    assign rs_o   = rs_tx;

endmodule
