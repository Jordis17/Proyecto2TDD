// =====================================================================
// top.sv - Integracion del sistema
//
// Aqui se instancian todos los modulos y se conectan entre si. Se
// trabaja con un solo reloj de 100 MHz: lo que necesita ir mas lento
// usa el tick de 1 ms o lleva su propio contador, de modo que no hay
// relojes derivados en ninguna parte.
//
// Cada periferico se maneja a traves de una cadena de tres niveles:
//
//   game_controller -> lcd_screen_ctrl -> lcd_peripheral -> lcd_controller
//   game_controller -> uart_msg        -> uart_peripheral -> uart_core
//
// El control del juego nunca escribe directamente en un periferico, lo
// hace siempre a traves de su capa de presentacion, y cada periferico
// tiene una sola capa que lo maneje.
//
// El reset viene del boton central y pasa por el mismo filtro que los
// otros dos botones. Ese filtro no se reinicia con nada, porque seria
// circular: sus registros arrancan con el valor que declara el codigo,
// que en la FPGA se carga desde el bitstream. Por lo mismo el juego
// funciona apenas se programa la tarjeta, sin pulsar nada.
//
// Con MODO_PRUEBA_UART en 1 el periferico UART lo maneja el bloque de
// pruebas en lugar de la capa de protocolo. Se decide por parametro, o
// sea en sintesis, y no queda ningun multiplexor en el camino.
// =====================================================================

module top #(
    parameter int   CLK_HZ            = 100_000_000,
    parameter int   TICK_CYCLES       = 100_000,     // 1 ms a 100 MHz
    parameter int   BAUD_DIV          = 868,         // 115200 baudios
    parameter int   DEBOUNCE_MS       = 10,
    parameter int   SEG_FACIL         = 60,
    parameter int   SEG_DIFICIL       = 45,
    parameter int   RESULT_MS         = 3000,
    parameter int   TICKS_POR_SEGUNDO = 1000,
    parameter logic MODO_PRUEBA_UART  = 1'b0,
    // polaridades de la tarjeta
    parameter logic BTN_ACTIVE_LEVEL  = 1'b1,
    parameter logic LED_ACTIVE_LEVEL  = 1'b1,
    parameter logic SEG_ACTIVE_LEVEL  = 1'b0,
    parameter logic AN_ACTIVE_LEVEL   = 1'b0,
    parameter logic AMP_ENABLE_LEVEL  = 1'b1,
    // tiempos del LCD, en ciclos del reloj principal
    parameter int   LCD_POWERON_TICKS = 50,
    parameter int   LCD_CIC_CORTA     = 6_000,
    parameter int   LCD_CIC_LARGA     = 200_000,
    parameter int   LCD_CIC_SETUP     = 20,
    parameter int   LCD_CIC_E_ALTO    = 100,
    parameter int   LCD_CIC_E_BAJO    = 100
) (
    input  logic       clk_i,

    input  logic       btn_rst_i,
    input  logic       btn_sel_i,
    input  logic       btn_ok_i,

    input  logic       uart_rx_i,
    output logic       uart_tx_o,

    output logic [7:0] lcd_db_o,
    output logic       lcd_rs_o,
    output logic       lcd_rw_o,
    output logic       lcd_e_o,

    output logic [6:0] seg_o,
    output logic [7:0] an_o,
    output logic [15:0] led_o,

    output logic       aud_pwm_o,
    output logic       aud_sd_o
);

    localparam int MAX_LEN = 12;
    localparam int N_WORDS = 64;

    // ---------------- reloj y reset ----------------
    logic tick;
    clk_tick_gen #(.TICK_CYCLES(TICK_CYCLES)) base_tiempo (
        .clk_i(clk_i), .rst_i(1'b0), .tick_o(tick)
    );

    // Cada boton entrega las dos formas, el nivel y el pulso, pero cada
    // uno usa solo la que le sirve. El reinicio se toma como nivel y los
    // otros dos como eventos, asi que la otra salida se deja sin conectar.
    logic rst, rst_pulso;
    logic btn_sel, btn_ok, nivel_sel, nivel_ok;

    // El filtro del boton de reinicio no puede depender del reinicio, por
    // eso este es el unico que recibe un cero fijo.
    button_input #(.DEBOUNCE_MS(DEBOUNCE_MS), .BTN_ACTIVE_LEVEL(BTN_ACTIVE_LEVEL))
    filtro_rst (
        .clk_i(clk_i), .rst_i(1'b0), .tick_i(tick), .btn_i(btn_rst_i),
        .pulse_o(rst_pulso), .level_o(rst)
    );

    button_input #(.DEBOUNCE_MS(DEBOUNCE_MS), .BTN_ACTIVE_LEVEL(BTN_ACTIVE_LEVEL))
    filtro_sel (
        .clk_i(clk_i), .rst_i(rst), .tick_i(tick), .btn_i(btn_sel_i),
        .pulse_o(btn_sel), .level_o(nivel_sel)
    );

    button_input #(.DEBOUNCE_MS(DEBOUNCE_MS), .BTN_ACTIVE_LEVEL(BTN_ACTIVE_LEVEL))
    filtro_ok (
        .clk_i(clk_i), .rst_i(rst), .tick_i(tick), .btn_i(btn_ok_i),
        .pulse_o(btn_ok), .level_o(nivel_ok)
    );

    // ---------------- banco de palabras y generador ----------------
    logic [$clog2(N_WORDS)-1:0] rom_index;
    logic [8*MAX_LEN-1:0]       rom_data;
    logic [3:0]                 rom_len;
    logic [7:0]                 lfsr_val;

    word_rom #(.N_WORDS(N_WORDS), .MAX_LEN(MAX_LEN)) banco (
        .index_i(rom_index), .word_data_o(rom_data), .word_len_o(rom_len)
    );

    lfsr generador (.clk_i(clk_i), .rst_i(rst), .lfsr_o(lfsr_val));

    // ---------------- temporizador ----------------
    logic       t_load, t_run, t_timeout;
    logic [6:0] t_seconds, t_valor;

    round_timer #(.TICKS_POR_SEGUNDO(TICKS_POR_SEGUNDO)) temporizador (
        .clk_i(clk_i), .rst_i(rst), .tick_i(tick),
        .load_i(t_load), .seconds_i(t_seconds), .run_i(t_run),
        .time_s_o(t_valor), .timeout_o(t_timeout)
    );

    // ---------------- control del juego ----------------
    logic [1:0]           ev_uart;
    logic                 send_uart, uart_busy;
    logic [7:0]           rx_letra;
    logic                 rx_valida;
    logic [2:0]           screen;
    logic                 redraw, lcd_busy;
    logic [8*MAX_LEN-1:0] word_data;
    logic [3:0]           word_len;
    logic [MAX_LEN-1:0]   revealed;
    logic [2:0]           errores_j;
    logic                 modo;
    logic [7:0]           letra_pub;
    logic                 hit;
    logic [1:0]           fin_cod;
    logic [2:0]           snd_ev;
    logic                 snd_start;
    logic [1:0]           estado;
    logic [7:0]           wins;

    game_controller #(
        .MAX_LEN(MAX_LEN), .N_WORDS(N_WORDS),
        .SEG_FACIL(SEG_FACIL), .SEG_DIFICIL(SEG_DIFICIL), .RESULT_MS(RESULT_MS)
    ) juego (
        .clk_i(clk_i), .rst_i(rst), .tick_i(tick),
        .btn_sel_i(btn_sel), .btn_ok_i(btn_ok),
        .lfsr_i(lfsr_val),
        .rom_index_o(rom_index), .rom_data_i(rom_data), .rom_len_i(rom_len),
        .timer_load_o(t_load), .timer_seconds_o(t_seconds),
        .timer_run_o(t_run), .timer_timeout_i(t_timeout),
        .rx_letter_i(rx_letra), .rx_valid_i(rx_valida),
        .uart_event_o(ev_uart), .uart_send_o(send_uart), .uart_busy_i(uart_busy),
        .screen_o(screen), .redraw_o(redraw), .lcd_busy_i(lcd_busy),
        .word_data_o(word_data), .word_len_o(word_len), .revealed_o(revealed),
        .errors_o(errores_j), .mode_o(modo), .letter_o(letra_pub),
        .hit_o(hit), .end_code_o(fin_cod),
        .snd_event_o(snd_ev), .snd_start_o(snd_start),
        .state_o(estado), .wins_bcd_o(wins)
    );

    // ---------------- cadena del LCD ----------------
    logic        lcd_we;
    logic [1:0]  lcd_addr;
    logic [31:0] lcd_wdata, lcd_rdata;
    logic        lcd_start, lcd_rs, lcd_done, lcd_ocupado;
    logic [7:0]  lcd_data;

    lcd_screen_ctrl #(.MAX_LEN(MAX_LEN)) pantalla (
        .clk_i(clk_i), .rst_i(rst),
        .screen_i(screen), .redraw_i(redraw), .busy_o(lcd_busy),
        .word_data_i(word_data), .word_len_i(word_len), .revealed_i(revealed),
        .errors_i(errores_j), .mode_i(modo), .wins_i(wins),
        .write_enable_o(lcd_we), .addr_o(lcd_addr),
        .wdata_o(lcd_wdata), .rdata_i(lcd_rdata)
    );

    lcd_peripheral periferico_lcd (
        .clk_i(clk_i), .rst_i(rst),
        .write_enable_i(lcd_we), .addr_i(lcd_addr),
        .wdata_i(lcd_wdata), .rdata_o(lcd_rdata),
        .start_o(lcd_start), .rs_o(lcd_rs), .data_o(lcd_data),
        .busy_i(lcd_ocupado), .done_i(lcd_done)
    );

    lcd_controller #(
        .POWERON_TICKS(LCD_POWERON_TICKS),
        .CIC_CORTA(LCD_CIC_CORTA), .CIC_LARGA(LCD_CIC_LARGA),
        .CIC_SETUP(LCD_CIC_SETUP),
        .CIC_E_ALTO(LCD_CIC_E_ALTO), .CIC_E_BAJO(LCD_CIC_E_BAJO)
    ) modulo_lcd (
        .clk_i(clk_i), .rst_i(rst), .tick_i(tick),
        .start_i(lcd_start), .rs_i(lcd_rs), .data_i(lcd_data),
        .busy_o(lcd_ocupado), .done_o(lcd_done),
        .lcd_db_o(lcd_db_o), .lcd_rs_o(lcd_rs_o),
        .lcd_rw_o(lcd_rw_o), .lcd_e_o(lcd_e_o)
    );

    // ---------------- cadena del UART ----------------
    // El periferico tiene un solo maestro. Cual de los dos sea se decide
    // por parametro, asi que despues de sintetizar solo queda uno.
    logic        msg_we, test_we, uart_we;
    logic [1:0]  msg_addr, test_addr, uart_addr;
    logic [31:0] msg_wdata, test_wdata, uart_wdata, uart_rdata;
    logic [7:0]  ultimo_rx;

    uart_msg #(.MAX_LEN(MAX_LEN)) protocolo (
        .clk_i(clk_i), .rst_i(rst),
        .event_i(ev_uart), .send_i(send_uart), .busy_o(uart_busy),
        .rx_letter_o(rx_letra), .rx_valid_o(rx_valida),
        .letter_i(letra_pub), .hit_i(hit), .end_code_i(fin_cod),
        .word_data_i(word_data), .word_len_i(word_len), .revealed_i(revealed),
        .errors_i(errores_j), .mode_i(modo),
        .write_enable_o(msg_we), .addr_o(msg_addr),
        .wdata_o(msg_wdata), .rdata_i(uart_rdata)
    );

    uart_test_block bloque_prueba (
        .clk_i(clk_i), .rst_i(rst), .tick_i(tick),
        .we_o(test_we), .addr_o(test_addr), .wdata_o(test_wdata),
        .rdata_i(uart_rdata), .ultimo_rx_o(ultimo_rx)
    );

    assign uart_we    = MODO_PRUEBA_UART ? test_we    : msg_we;
    assign uart_addr  = MODO_PRUEBA_UART ? test_addr  : msg_addr;
    assign uart_wdata = MODO_PRUEBA_UART ? test_wdata : msg_wdata;

    logic [7:0] tx_data, rx_data;
    logic       tx_start, tx_busy, rx_valid;

    uart_peripheral periferico_uart (
        .clk_i(clk_i), .rst_i(rst),
        .write_enable_i(uart_we), .addr_i(uart_addr),
        .wdata_i(uart_wdata), .rdata_o(uart_rdata),
        .tx_data_o(tx_data), .tx_start_o(tx_start), .tx_busy_i(tx_busy),
        .rx_data_i(rx_data), .rx_valid_i(rx_valid)
    );

    // El receptor del nucleo sobremuestrea a 16 veces el baudaje, asi que su
    // divisor es el del transmisor entre 16. Se deriva de BAUD_DIV para que los
    // dos no puedan quedar descuadrados, ni aca ni al reducirlos en simulacion.
    localparam int BAUD_X16_DIV = (BAUD_DIV + 8) / 16;

    uart_core #(.BAUD_DIV(BAUD_DIV), .BAUD_X16_DIV(BAUD_X16_DIV)) nucleo_uart (
        .clk_i(clk_i), .rst_i(rst),
        .tx_o(uart_tx_o), .rx_i(uart_rx_i),
        .tx_data_i(tx_data), .tx_start_i(tx_start), .tx_busy_o(tx_busy),
        .rx_data_o(rx_data), .rx_valid_o(rx_valid)
    );

    // ---------------- salidas de estado ----------------
    display_controller #(
        .SEG_ACTIVE_LEVEL(SEG_ACTIVE_LEVEL), .AN_ACTIVE_LEVEL(AN_ACTIVE_LEVEL)
    ) displays (
        .clk_i(clk_i), .rst_i(rst), .tick_i(tick),
        .time_s_i(t_valor), .wins_bcd_i(wins),
        .seg_o(seg_o), .an_o(an_o)
    );

    // En modo de prueba los LEDs muestran el ultimo byte que llego por el
    // serial, para poder comprobar la comunicacion viendo la tarjeta.
    logic [15:0] led_juego;
    led_controller #(.LED_ACTIVE_LEVEL(LED_ACTIVE_LEVEL)) leds (
        .state_i(estado), .mode_i(modo), .led_o(led_juego)
    );

    assign led_o = MODO_PRUEBA_UART ? {8'd0, ultimo_rx} : led_juego;

    buzzer_controller #(
        .CLK_HZ(CLK_HZ), .AMP_ENABLE_LEVEL(AMP_ENABLE_LEVEL)
    ) sonido (
        .clk_i(clk_i), .rst_i(rst), .tick_i(tick),
        .snd_event_i(snd_ev), .snd_start_i(snd_start),
        .aud_pwm_o(aud_pwm_o), .aud_sd_o(aud_sd_o),
        // La politica de solapamiento de sonidos vive dentro del propio
        // modulo, asi que nadie necesita saber si esta sonando algo.
        .busy_o()
    );

endmodule
