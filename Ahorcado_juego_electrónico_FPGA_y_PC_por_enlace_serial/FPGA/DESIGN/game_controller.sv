// =====================================================================
// game_controller.sv - Reglas de la partida
//
// Este modulo es el encargado de controlar la partida de ahorcado, contiene los doce estados necesarios para la lógica del juego.
//
//
// -------
//   DIBUJA_SEL     pide la pantalla de seleccion
//   SELECCION      BTN_SEL cambia el modo, BTN_OK empieza la partida
//   CARGA          indice -> ROM -> registra palabra; limpia el estado;
//                  carga el temporizador
//   INICIO         dispara pantalla y trama de comienzo
//   ESPERA_INICIO  espera a que las dos capas queden libres
//   JUGANDO        descuenta; atiende la letra o el vencimiento
//   EVALUA         un ciclo: compara, revela, cuenta el error
//   PUBLICA        dispara lo que corresponda a la jugada
//   ESPERA_JUGADA  espera las dos capas y resuelve el desenlace
//   FIN            dispara pantalla de resultado, trama y sonido
//   ESPERA_FIN     espera las dos capas y arranca los tres segundos
//   RESULTADO      cuenta los tres segundos y vuelve a la seleccion
//
// Hay un solo estado de fin, que contiene los tres posibles resultados: victoria, derrota por letras y derrota por tiempo. 
// ------------------------------

module game_controller #(
    parameter int MAX_LEN     = 12, // longitud maxima de palabra
    parameter int N_WORDS     = 64, // cantidad de palabras en el banco
    parameter int SEG_FACIL   = 60, // duracion de la partida facil en segundos
    parameter int SEG_DIFICIL = 45, // duracion de la partida dificil en segundos
    parameter int RESULT_MS   = 3000     // duracion de la pantalla de resultado
) (
    input  logic clk_i,
    input  logic rst_i,
    input  logic tick_i,               // pulso de 1 ms

    // botones, ya filtrados, un pulso por pulsacion
    input  logic btn_sel_i,
    input  logic btn_ok_i,

    // Generador pseudoaleatorio, siempre en funcion. Se conecta entero
    // aunque solo se usen los seis bits bajos: la seleccion es por
    // truncamiento y descartar los dos altos es la decision, no un olvido.
   
    input  logic [7:0] lfsr_i,
 

    // banco de palabras
    output logic [$clog2(N_WORDS)-1:0] rom_index_o,
    input  logic [8*MAX_LEN-1:0]       rom_data_i,
    input  logic [3:0]                 rom_len_i,

    // temporizador de la partida
    output logic       timer_load_o,
    output logic [6:0] timer_seconds_o,
    output logic       timer_run_o,
    input  logic       timer_timeout_i,

    // capa de protocolo
    input  logic [7:0] rx_letter_i,
    input  logic       rx_valid_i,
    output logic [1:0] uart_event_o,
    output logic       uart_send_o,
    input  logic       uart_busy_i,

    // capa de pantalla
    output logic [2:0] screen_o,
    output logic       redraw_o,
    input  logic       lcd_busy_i,

    // datos que consumen las dos capas
    output logic [8*MAX_LEN-1:0] word_data_o,
    output logic [3:0]           word_len_o,
    output logic [MAX_LEN-1:0]   revealed_o,
    output logic [2:0]           errors_o,
    output logic                 mode_o,
    output logic [7:0]           letter_o,
    output logic                 hit_o,
    output logic [1:0]           end_code_o,

    // sonido
    output logic [2:0] snd_event_o,
    output logic       snd_start_o,

    // estado visible
    output logic [1:0] state_o,        // 00 seleccion, 01 partida, 10 resultado
    output logic [7:0] wins_bcd_o
);

    // codigos de pantalla, iguales a los de lcd_screen_ctrl
    localparam logic [2:0] SCR_SELECT      = 3'd0;
    localparam logic [2:0] SCR_PLAY        = 3'd1;
    localparam logic [2:0] SCR_WIN         = 3'd2;
    localparam logic [2:0] SCR_LOSE_FALLOS = 3'd3;
    localparam logic [2:0] SCR_LOSE_TIEMPO = 3'd4;

    // codigos de evento, iguales a los de uart_msg
    localparam logic [1:0] EV_INICIO   = 2'd0;
    localparam logic [1:0] EV_LETRA    = 2'd1;
    localparam logic [1:0] EV_REPETIDA = 2'd2;
    localparam logic [1:0] EV_FIN      = 2'd3;

    // codigos de sonido, iguales a los de buzzer_controller
    localparam logic [2:0] SND_NINGUNO  = 3'd0;
    localparam logic [2:0] SND_ACIERTO  = 3'd1;
    localparam logic [2:0] SND_ERROR    = 3'd2;
    localparam logic [2:0] SND_VICTORIA = 3'd3;
    localparam logic [2:0] SND_DERROTA  = 3'd4;

    // desenlace de la partida
    localparam logic [1:0] FIN_WIN = 2'd0;
    localparam logic [1:0] FIN_LER = 2'd1;
    localparam logic [1:0] FIN_LTO = 2'd2;

    // parametros de la partida
    localparam logic [2:0] MAX_ERR = 3'd6;
    localparam logic [7:0] CAR_A   = 8'h41;
    localparam int         W_MS    = $clog2(RESULT_MS);

    //estados necesarios para la maquina de estados
    typedef enum logic [3:0] {
        S_DIBUJA_SEL,
        S_SELECCION,
        S_CARGA,
        S_INICIO,
        S_ESPERA_INICIO,
        S_JUGANDO,
        S_EVALUA,
        S_PUBLICA,
        S_ESPERA_JUGADA,
        S_FIN,
        S_ESPERA_FIN,
        S_RESULTADO
    } estado_t;

    estado_t st_q = S_DIBUJA_SEL;

    //registros de la partida

    logic [8*MAX_LEN-1:0] word_q     = '0;
    logic [3:0]           len_q      = 4'd0;
    logic [MAX_LEN-1:0]   rev_q      = '0;
    logic [25:0]          usadas_q   = '0;
    logic [2:0]           err_q      = 3'd0;
    logic                 mode_q     = 1'b0;
    logic [7:0]           letra_q    = 8'h41;
    logic                 hit_q      = 1'b0;
    logic                 rpt_q      = 1'b0;   // la ultima letra era repetida
    logic                 victoria_q = 1'b0;
    logic [1:0]           fin_q      = FIN_WIN;
    logic [7:0]           wins_q     = 8'h00;
    logic [5:0]           lfsr_cap_q = 6'd1;
    logic [W_MS-1:0]      ms_q       = '0;

    assign word_data_o = word_q;
    assign word_len_o  = len_q;
    assign revealed_o  = rev_q;
    assign errors_o    = err_q;
    assign mode_o      = mode_q;
    assign letter_o    = letra_q;
    assign hit_o       = hit_q;
    assign end_code_o  = fin_q;
    assign wins_bcd_o  = wins_q;

    // ---------------------------------------------------------------
    // Seleccion de la palabra
    // ---------------------------------------------------------------
    // Del generador solo se guardan seis bits, que es todo lo que hace
    // falta: en dificil se usan cinco y el indice cae en 0..31, el tramo
    // de palabras largas; en facil se usan los seis, ya que ahí se usa todo el banco de 64 palabras.

    assign rom_index_o = mode_q ? {1'b0, lfsr_cap_q[4:0]} : lfsr_cap_q;

    // ---------------------------------------------------------------
    // Evaluacion de la letra
    // ---------------------------------------------------------------
    // La comparacion es contra todas las posiciones a la vez, de modo que
    // una letra repetida dentro de la palabra revela todas sus apariciones
    // en el mismo paso.

    logic [MAX_LEN-1:0] coincide, mascara_valida, rev_next;
    logic               acierto, gana;
    logic [4:0]         idx_letra;
    logic [2:0]         err_next;

    always_comb begin
        for (int c = 0; c < MAX_LEN; c++) begin
            mascara_valida[c] = (c < {1'b0, len_q});
            coincide[c]       = (c < {1 me'b0, len_q}) &&
                                (word_q[8*(MAX_LEN-1-c) +: 8] == letra_q);
        end
    end

    assign acierto   = |coincide;
    assign rev_next  = rev_q | coincide;
    assign gana      = (rev_next == mascara_valida);
    assign err_next  = acierto ? err_q : err_q + 3'd1;
    assign idx_letra = letra_q[4:0] - CAR_A[4:0];   // la letra ya viene validada

    // ---------------------------------------------------------------
    // Contador de victorias en BCD, con saturacion en 99
    // ---------------------------------------------------------------

    logic [3:0] win_dec, win_uni;
    logic [7:0] wins_next;
    assign win_dec   = wins_q[7:4];
    assign win_uni   = wins_q[3:0];
    assign wins_next = (wins_q == 8'h99) ? 8'h99
                     : (win_uni == 4'd9) ? {win_dec + 4'd1, 4'd0}
                                         : {win_dec, win_uni + 4'd1};

endmodule