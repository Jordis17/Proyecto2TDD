// =====================================================================
// game_controller.sv - Reglas de la partida
//
// Este esta destino para ser el controlador de la partida, que se encarga de:
//
// Estados que se ven en el diagrama de estados y en la tabla de transiciones
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
// Un solo estado de fin, que contiene los tre sposibles reultados: victoria, derrota por letras y derrota por tiempo. 
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

    localparam logic [2:0] MAX_ERR = 3'd6;
    localparam logic [7:0] CAR_A   = 8'h41;
    localparam int         W_MS    = $clog2(RESULT_MS);

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

endmodule