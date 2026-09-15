// =====================================================================
// tb_game_controller.sv - Testbench autoverificable de las reglas
//
// El banco de palabras, el generador y el temporizador son los modulos
// reales. Las dos capas de presentacion se sustituyen por modelos que
// solo se declaran ocupados durante un numero de ciclos configurable y
// anotan cada orden recibida: aqui se verifican las reglas del juego, no
// como se pinta una pantalla ni como se arma una trama, que ya tienen su
// propio testbench.
//
// Poder alargar a voluntad lo que tardan las capas es lo que permite
// provocar el caso dificil: que el tiempo se agote justo mientras hay una
// publicacion a medias.
//
// Comprueba:
//   1. arranca en la pantalla de seleccion y la pide una sola vez
//   2. BTN_SEL alterna el modo y vuelve a pedir la pantalla
//   3. BTN_OK carga el temporizador con 60 s en facil y 45 s en dificil
//   4. en dificil la palabra siempre tiene 6 letras o mas
//   5. al empezar se publican la pantalla de partida y el evento de inicio
//   6. una letra correcta revela todas sus posiciones a la vez y no sube
//      los errores
//   7. una letra incorrecta sube los errores y suena distinto
//   8. una letra repetida no cambia nada y solo se avisa a la PC
//   9. completar la palabra gana y sube el contador de victorias
//  10. el sexto error pierde aunque quede tiempo
//  11. agotar el tiempo pierde
//  12. con victoria y vencimiento a la vez gana la victoria
//  13. el vencimiento durante una publicacion se atiende al terminarla
//  14. las letras recibidas fuera de la partida se ignoran
//  15. el resultado se muestra y vuelve solo a la seleccion
//  16. el contador de victorias arrastra bien y satura en 99
//  17. nunca se da una orden a una capa que esta ocupada
//
// Ejecutar:
//   iverilog -g2012 -o tb tb_game_controller.sv ../DESIGN/game_controller.sv \
//            ../DESIGN/word_rom.sv ../DESIGN/lfsr.sv ../DESIGN/round_timer.sv
//   ./tb
// =====================================================================
`timescale 1ns/1ps

module tb_game_controller;

    localparam int MAX_LEN     = 12;
    localparam int N_WORDS     = 64;
    localparam int SEG_FACIL   = 60;
    localparam int SEG_DIFICIL = 45;
    localparam int RESULT_MS   = 60;     // reducido, pero largo comparado con una publicacion
    localparam int TICK_DIV    = 2;
    localparam int TICKS_SEG   = 20;     // un "segundo" son 40 ciclos

    localparam logic [2:0] SCR_SELECT      = 3'd0;
    localparam logic [2:0] SCR_PLAY        = 3'd1;
    localparam logic [2:0] SCR_WIN         = 3'd2;
    localparam logic [2:0] SCR_LOSE_FALLOS = 3'd3;
    localparam logic [2:0] SCR_LOSE_TIEMPO = 3'd4;

    localparam logic [1:0] EV_INICIO   = 2'd0;
    localparam logic [1:0] EV_LETRA    = 2'd1;
    localparam logic [1:0] EV_REPETIDA = 2'd2;
    localparam logic [1:0] EV_FIN      = 2'd3;

    localparam logic [2:0] SND_ACIERTO  = 3'd1;
    localparam logic [2:0] SND_ERROR    = 3'd2;
    localparam logic [2:0] SND_VICTORIA = 3'd3;
    localparam logic [2:0] SND_DERROTA  = 3'd4;

    localparam logic [1:0] ST_SEL = 2'b00;
    localparam logic [1:0] ST_JUE = 2'b01;
    localparam logic [1:0] ST_RES = 2'b10;

    logic clk = 1'b0;
    logic rst = 1'b0;

    logic btn_sel = 1'b0;
    logic btn_ok  = 1'b0;

    logic [7:0] rx_letra = 8'h41;
    logic       rx_val   = 1'b0;

    // ---- conexiones ----
    logic [5:0]           rom_index;
    logic [8*MAX_LEN-1:0] rom_data;
    logic [3:0]           rom_len;
    logic [7:0]           lfsr_val;

    logic       t_load, t_run, t_timeout;
    logic [6:0] t_seconds;
    logic [6:0] t_valor;

    logic [1:0] ev_uart;
    logic       send_uart;
    logic [2:0] screen;
    logic       redraw;
    logic [2:0] snd_ev;
    logic       snd_start;

    logic [8*MAX_LEN-1:0] word_data;
    logic [3:0]           word_len;
    logic [MAX_LEN-1:0]   revealed;
    logic [2:0]           errores_j;
    logic                 modo;
    logic [7:0]           letra_pub;
    logic                 hit;
    logic [1:0]           fin_cod;
    logic [1:0]           estado;
    logic [7:0]           wins;

    int errores = 0;

    always #5 clk = ~clk;

    int tick_cnt = 0;
    logic tick;
    assign tick = (tick_cnt == TICK_DIV - 1);
    always_ff @(posedge clk) tick_cnt <= tick ? 0 : tick_cnt + 1;

    // ---- modelos de las dos capas ----
    // Se quedan ocupadas el numero de ciclos que diga la variable, que el
    // testbench cambia para provocar los casos dificiles.
    int CIC_LCD  = 6;
    int CIC_UART = 9;

    int   lcd_cnt = 0, uart_cnt = 0;
    logic lcd_busy, uart_busy;
    assign lcd_busy  = (lcd_cnt  != 0);
    assign uart_busy = (uart_cnt != 0);

    always_ff @(posedge clk) begin
        if (redraw && lcd_cnt == 0) lcd_cnt <= CIC_LCD;
        else if (lcd_cnt > 0)       lcd_cnt <= lcd_cnt - 1;

        if (send_uart && uart_cnt == 0) uart_cnt <= CIC_UART;
        else if (uart_cnt > 0)          uart_cnt <= uart_cnt - 1;
    end

    // ---- anotacion de ordenes ----
    int         n_scr = 0, n_msg = 0, n_snd = 0;
    logic [2:0] ult_scr, ult_snd;
    logic [1:0] ult_msg;

    always_ff @(posedge clk) begin
        if (redraw)    begin ult_scr <= screen;  n_scr <= n_scr + 1; end
        if (send_uart) begin ult_msg <= ev_uart; n_msg <= n_msg + 1; end
        if (snd_start) begin ult_snd <= snd_ev;  n_snd <= n_snd + 1; end
    end

    // ---- 17: invariante permanente ----
    // Ninguna capa debe recibir una orden mientras esta ocupada: se
    // perderia en silencio, que es la peor forma de fallar.
    always_ff @(posedge clk) begin
        if (redraw && lcd_busy) begin
            $display("  FAIL: se pidio un dibujo con la pantalla ocupada");
            errores <= errores + 1;
        end
        if (send_uart && uart_busy) begin
            $display("  FAIL: se pidio una trama con el protocolo ocupado");
            errores <= errores + 1;
        end
    end

    // ---- modulos reales ----
    word_rom #(.N_WORDS(N_WORDS), .MAX_LEN(MAX_LEN)) rom (
        .index_i(rom_index), .word_data_o(rom_data), .word_len_o(rom_len)
    );

    lfsr generador (.clk_i(clk), .rst_i(rst), .lfsr_o(lfsr_val));

    round_timer #(.TICKS_POR_SEGUNDO(TICKS_SEG)) temporizador (
        .clk_i(clk), .rst_i(rst), .tick_i(tick),
        .load_i(t_load), .seconds_i(t_seconds), .run_i(t_run),
        .time_s_o(t_valor), .timeout_o(t_timeout)
    );

    game_controller #(
        .MAX_LEN(MAX_LEN), .N_WORDS(N_WORDS),
        .SEG_FACIL(SEG_FACIL), .SEG_DIFICIL(SEG_DIFICIL), .RESULT_MS(RESULT_MS)
    ) dut (
        .clk_i(clk), .rst_i(rst), .tick_i(tick),
        .btn_sel_i(btn_sel), .btn_ok_i(btn_ok),
        .lfsr_i(lfsr_val),
        .rom_index_o(rom_index), .rom_data_i(rom_data), .rom_len_i(rom_len),
        .timer_load_o(t_load), .timer_seconds_o(t_seconds),
        .timer_run_o(t_run), .timer_timeout_i(t_timeout),
        .rx_letter_i(rx_letra), .rx_valid_i(rx_val),
        .uart_event_o(ev_uart), .uart_send_o(send_uart), .uart_busy_i(uart_busy),
        .screen_o(screen), .redraw_o(redraw), .lcd_busy_i(lcd_busy),
        .word_data_o(word_data), .word_len_o(word_len), .revealed_o(revealed),
        .errors_o(errores_j), .mode_o(modo), .letter_o(letra_pub),
        .hit_o(hit), .end_code_o(fin_cod),
        .snd_event_o(snd_ev), .snd_start_o(snd_start),
        .state_o(estado), .wins_bcd_o(wins)
    );

    // ---- utilidades ----
    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $display("  FAIL: %s", msg);
            errores++;
        end
    endtask

    logic [6:0] seg_cargados = 7'd0;
    always_ff @(posedge clk) if (t_load) seg_cargados <= t_seconds;

    task automatic pulso_sel;
        @(negedge clk); btn_sel = 1'b1;
        @(negedge clk); btn_sel = 1'b0;
    endtask

    task automatic pulso_ok;
        @(negedge clk); btn_ok = 1'b1;
        @(negedge clk); btn_ok = 1'b0;
    endtask

    task automatic mandar_letra(input logic [7:0] c);
        @(negedge clk); rx_letra = c; rx_val = 1'b1;
        @(negedge clk); rx_val = 1'b0;
    endtask

    // Espera a que no pase nada durante k ciclos seguidos. Sirve igual
    // para una jugada normal que para una que termina la partida, porque
    // en ese caso el fin encadena otra publicacion.
    task automatic esperar_quieto(input int k);
        int quietos, guardia;
        quietos = 0;
        guardia = 0;
        while (quietos < k && guardia < 500000) begin
            @(posedge clk);
            guardia++;
            if (lcd_busy || uart_busy) quietos = 0;
            else                       quietos++;
        end
        check(guardia < 500000, "las capas nunca se quedaron quietas");
    endtask

    task automatic esperar_estado(input logic [1:0] s, input string que);
        int guardia;
        guardia = 0;
        while (estado !== s && guardia < 500000) begin
            @(posedge clk);
            guardia++;
        end
        check(guardia < 500000, que);
        // El cambio de estado y la orden que lo acompana ocurren en el
        // mismo flanco, asi que hay que dejar pasar unos ciclos antes de
        // mirar lo que quedo anotado.
        repeat (4) @(posedge clk);
    endtask

    // caracter de la posicion p de la palabra en juego
    function automatic logic [7:0] car_palabra(input int p);
        return word_data[8*(MAX_LEN-1-p) +: 8];
    endfunction

    function automatic bit esta_en_palabra(input logic [7:0] c);
        for (int i = 0; i < MAX_LEN; i++) begin
            if (i < int'(word_len) && car_palabra(i) == c) return 1'b1;
        end
        return 1'b0;
    endfunction

    // la n-esima letra del alfabeto que no aparece en la palabra
    function automatic logic [7:0] letra_ausente(input int n);
        int vistas;
        logic [7:0] c;
        vistas = 0;
        for (int i = 0; i < 26; i++) begin
            c = 8'h41 + 8'(i);
            if (!esta_en_palabra(c)) begin
                if (vistas == n) return c;
                vistas++;
            end
        end
        return 8'h41;
    endfunction

    // juega todas las letras de la palabra hasta ganar
    task automatic ganar_partida;
        pulso_ok;
        esperar_quieto(20);
        for (int i = 0; i < MAX_LEN; i++) begin
            if (estado == ST_JUE && i < int'(word_len)) begin
                mandar_letra(car_palabra(i));
                esperar_quieto(20);
            end
        end
        esperar_estado(ST_RES, "la partida ganada no llego al resultado");
        esperar_estado(ST_SEL, "no volvio solo a la pantalla de seleccion");
        esperar_quieto(20);              // deja terminar el dibujo de la seleccion
    endtask

    // Manda letras hasta dejar la palabra a una sola letra de completarse
    // y devuelve cual es esa letra. Sirve para provocar el caso en que la
    // victoria y el vencimiento del tiempo coinciden.
    task automatic revelar_casi_todo(output logic [7:0] ultima);
        int  ocultas, iguales, p0;
        bit  listo;
        ultima = 8'h41;
        listo  = 1'b0;
        while (!listo) begin
            p0 = -1;
            for (int j = 0; j < MAX_LEN; j++) begin
                if (p0 < 0 && j < int'(word_len) && !revealed[j]) p0 = j;
            end
            if (p0 < 0) begin
                listo = 1'b1;                  // ya no queda nada oculto
            end else begin
                ocultas = 0;
                iguales = 0;
                for (int j = 0; j < MAX_LEN; j++) begin
                    if (j < int'(word_len) && !revealed[j]) begin
                        ocultas++;
                        if (car_palabra(j) == car_palabra(p0)) iguales++;
                    end
                end
                if (ocultas == iguales) begin
                    ultima = car_palabra(p0);  // esta letra completa la palabra
                    listo  = 1'b1;
                end else begin
                    mandar_letra(car_palabra(p0));
                    esperar_quieto(20);
                end
            end
        end
    endtask

    // ---------------------------------------------------------------
    initial begin
        int n_ini;
        logic [8*MAX_LEN-1:0] pal;
        logic [MAX_LEN-1:0]   rev_antes;
        logic [7:0]           ultima;

        $display("");
        $display("=== tb_game_controller ===");

        // ---------- 1: arranque ----------
        repeat (4) @(negedge clk);
        check(estado === ST_SEL, "no arranco en la pantalla de seleccion");
        check(modo === 1'b0, "el modo inicial deberia ser facil");
        check(wins === 8'h00, "el contador de victorias no arranco en cero");
        esperar_quieto(20);
        check(n_scr == 1, $sformatf("pidio %0d dibujos de la seleccion en vez de uno", n_scr));
        check(ult_scr === SCR_SELECT, "la pantalla pedida no es la de seleccion");
        check(n_msg == 0, "no debe mandarse nada a la PC en la seleccion");

        // ---------- 2: cambio de modo ----------
        pulso_sel;
        esperar_quieto(20);
        check(modo === 1'b1, "BTN_SEL no cambio a dificil");
        check(n_scr == 2, "cambiar de modo no volvio a pedir la pantalla");
        pulso_sel;
        esperar_quieto(20);
        check(modo === 1'b0, "BTN_SEL no volvio a facil");

        // ---------- 14a: letra en la seleccion ----------
        n_msg = 0;
        mandar_letra("A");
        esperar_quieto(20);
        check(n_msg == 0, "una letra recibida en la seleccion no debe hacer nada");
        check(estado === ST_SEL, "una letra recibida saco de la seleccion");

        // ---------- 3 y 5: comienzo de partida en facil ----------
        n_scr = 0; n_msg = 0;
        pulso_ok;
        esperar_quieto(20);
        check(estado === ST_JUE, "BTN_OK no arranco la partida");
        check(seg_cargados == 7'(SEG_FACIL),
              $sformatf("en facil se cargaron %0d s en vez de %0d", seg_cargados, SEG_FACIL));
        check(n_scr == 1 && ult_scr === SCR_PLAY, "no se pinto la pantalla de partida");
        check(n_msg == 1 && ult_msg === EV_INICIO, "no se aviso del comienzo a la PC");
        check(revealed === '0, "la palabra deberia empezar entera oculta");
        check(errores_j === 3'd0, "los errores deberian empezar en cero");
        check(word_len >= 4'd4, "la palabra es mas corta de lo que admite el banco");

        // ---------- 6: letra correcta ----------
        pal = word_data;
        n_scr = 0; n_msg = 0; n_snd = 0;
        mandar_letra(car_palabra(0));
        esperar_quieto(20);
        check(errores_j === 3'd0, "una letra correcta subio los errores");
        check(revealed[0] === 1'b1, "no se revelo la posicion acertada");
        check(hit === 1'b1, "no se marco como acierto");
        check(n_msg == 1 && ult_msg === EV_LETRA, "no se aviso de la letra");
        check(n_scr == 1 && ult_scr === SCR_PLAY, "no se redibujo el patron");
        check(n_snd == 1 && ult_snd === SND_ACIERTO, "no sono el acierto");
        check(word_data === pal, "la palabra cambio a mitad de la partida");
        // todas las posiciones con esa letra tienen que estar reveladas
        for (int i = 0; i < MAX_LEN; i++) begin
            if (i < int'(word_len) && car_palabra(i) == car_palabra(0)) begin
                check(revealed[i] === 1'b1,
                      "una posicion con la misma letra quedo sin revelar");
            end
        end

        // ---------- 8: letra repetida ----------
        rev_antes = revealed;
        n_scr = 0; n_msg = 0; n_snd = 0;
        mandar_letra(car_palabra(0));
        esperar_quieto(20);
        check(n_msg == 1 && ult_msg === EV_REPETIDA, "no se aviso de la letra repetida");
        check(n_scr == 0, "una letra repetida no deberia redibujar");
        check(n_snd == 0, "una letra repetida no deberia sonar");
        check(revealed === rev_antes, "una letra repetida cambio el patron");
        check(errores_j === 3'd0, "una letra repetida subio los errores");

        // ---------- 7: letra incorrecta ----------
        n_scr = 0; n_msg = 0; n_snd = 0;
        mandar_letra(letra_ausente(0));
        esperar_quieto(20);
        check(errores_j === 3'd1, "una letra incorrecta no subio los errores");
        check(hit === 1'b0, "se marco como acierto una letra incorrecta");
        check(n_snd == 1 && ult_snd === SND_ERROR, "no sono el error");
        check(n_scr == 1, "no se redibujo tras el fallo");

        // y una repetida incorrecta tampoco vuelve a contar
        n_msg = 0;
        mandar_letra(letra_ausente(0));
        esperar_quieto(20);
        check(errores_j === 3'd1, "una letra incorrecta repetida volvio a contar");
        check(ult_msg === EV_REPETIDA, "no se aviso como repetida");

        // ---------- 10: sexto error ----------
        n_snd = 0;
        for (int i = 1; i < 6; i++) begin
            mandar_letra(letra_ausente(i));
            esperar_quieto(20);
        end
        check(errores_j === 3'd6, $sformatf("se contaron %0d errores en vez de seis", errores_j));
        esperar_estado(ST_RES, "el sexto error no termino la partida");
        check(fin_cod === 2'd1, "el desenlace no fue derrota por fallos");
        check(ult_scr === SCR_LOSE_FALLOS, "no se pinto la pantalla de fallos");
        check(ult_msg === EV_FIN, "no se aviso del final a la PC");
        check(ult_snd === SND_DERROTA, "no sono la derrota");
        check(wins === 8'h00, "perder subio el contador de victorias");

        // ---------- 14b: letra mostrando el resultado ----------
        n_msg = 0;
        mandar_letra("A");
        repeat (5) @(posedge clk);
        check(n_msg == 0, "una letra recibida en el resultado no debe hacer nada");

        // ---------- 15: vuelta sola a la seleccion ----------
        esperar_estado(ST_SEL, "no volvio solo a la seleccion tras el resultado");
        esperar_quieto(20);

        // ---------- 3b y 4: dificil ----------
        pulso_sel;
        esperar_quieto(20);
        check(modo === 1'b1, "no quedo en dificil");
        for (int p = 0; p < 6; p++) begin
            pulso_ok;
            esperar_quieto(20);
            check(seg_cargados == 7'(SEG_DIFICIL),
                  $sformatf("en dificil se cargaron %0d s en vez de %0d",
                            seg_cargados, SEG_DIFICIL));
            check(word_len >= 4'd6,
                  $sformatf("en dificil salio una palabra de %0d letras", word_len));
            // se pierde por fallos para volver rapido a la seleccion
            for (int i = 0; i < 6; i++) begin
                mandar_letra(letra_ausente(i));
                esperar_quieto(20);
            end
            esperar_estado(ST_SEL, "no volvio a la seleccion");
            esperar_quieto(20);
        end
        pulso_sel;                       // de vuelta a facil
        esperar_quieto(20);

        // ---------- 9: victoria y contador ----------
        n_ini = int'(wins);
        check(n_ini == 0, "el contador deberia seguir en cero");
        ganar_partida;
        check(wins === 8'h01, $sformatf("tras ganar el contador quedo en %02h", wins));

        // ---------- 11: derrota por tiempo ----------
        pulso_ok;
        esperar_quieto(20);
        check(estado === ST_JUE, "no arranco la partida");
        // se deja correr el reloj sin mandar nada
        esperar_estado(ST_RES, "el tiempo no termino la partida");
        check(fin_cod === 2'd2, "el desenlace no fue derrota por tiempo");
        check(ult_scr === SCR_LOSE_TIEMPO, "no se pinto la pantalla de tiempo");
        check(ult_snd === SND_DERROTA, "no sono la derrota por tiempo");
        esperar_estado(ST_SEL, "no volvio a la seleccion");
        esperar_quieto(20);

        // ---------- 13: vencimiento durante una publicacion ----------
        // Con las capas lentas, el tiempo se agota mientras se esta
        // publicando una jugada. La publicacion no debe cortarse.
        // El limite de la partida son 60 s y aqui un segundo son 40
        // ciclos, asi que una publicacion de 2600 ciclos se pasa del
        // vencimiento y lo obliga a esperar.
        CIC_LCD  = 2000;
        CIC_UART = 2600;
        pulso_ok;
        esperar_quieto(20);
        n_scr = 0; n_msg = 0;
        mandar_letra(car_palabra(0));    // publicacion larga en curso
        esperar_estado(ST_RES, "el vencimiento durante la publicacion no termino la partida");
        check(fin_cod === 2'd2, "el desenlace deberia ser derrota por tiempo");
        check(n_msg == 2, $sformatf("se publicaron %0d tramas en vez de dos", n_msg));
        esperar_estado(ST_SEL, "no volvio a la seleccion");
        CIC_LCD  = 6;
        CIC_UART = 9;
        esperar_quieto(20);

        // ---------- 9b: victoria normal ----------
        ganar_partida;
        check(fin_cod === 2'd0, "el desenlace deberia ser victoria");
        check(wins === 8'h02, $sformatf("el contador quedo en %02h en vez de 02", wins));

        // ---------- 12a: victoria contra vencimiento ----------
        // Se deja la palabra a una letra de completarse, se espera a que
        // queden dos segundos y se manda la letra ganadora con las capas
        // lentas: el tiempo se agota durante la publicacion, de modo que
        // al resolver la jugada la victoria y el vencimiento estan activos
        // a la vez. Debe ganar la victoria.
        pulso_ok;
        esperar_quieto(20);
        revelar_casi_todo(ultima);
        while (t_valor > 7'd2) @(posedge clk);
        CIC_LCD  = 200;
        CIC_UART = 200;
        mandar_letra(ultima);
        esperar_estado(ST_RES, "la jugada ganadora no termino la partida");
        check(t_valor === 7'd0,
              "para esta prueba el contador tenia que haber llegado a cero");
        check(fin_cod === 2'd0,
              "con victoria y vencimiento a la vez no gano la victoria");
        check(wins === 8'h03, $sformatf("el contador quedo en %02h en vez de 03", wins));
        esperar_estado(ST_SEL, "no volvio a la seleccion");
        CIC_LCD  = 6;
        CIC_UART = 9;
        esperar_quieto(20);

        // ---------- 12b: sexto error contra vencimiento ----------
        // Mismo montaje, pero la ultima jugada es el sexto fallo. Debe
        // perder por fallos y no por tiempo.
        pulso_ok;
        esperar_quieto(20);
        for (int i = 0; i < 5; i++) begin
            mandar_letra(letra_ausente(i));
            esperar_quieto(20);
        end
        check(errores_j === 3'd5, "no se acumularon cinco errores");
        while (t_valor > 7'd2) @(posedge clk);
        CIC_LCD  = 200;
        CIC_UART = 200;
        mandar_letra(letra_ausente(5));
        esperar_estado(ST_RES, "el sexto error no termino la partida");
        check(t_valor === 7'd0,
              "para esta prueba el contador tenia que haber llegado a cero");
        check(fin_cod === 2'd1,
              "con sexto error y vencimiento a la vez no gano el sexto error");
        esperar_estado(ST_SEL, "no volvio a la seleccion");
        CIC_LCD  = 6;
        CIC_UART = 9;
        esperar_quieto(20);

        // ---------- 16: arrastre y saturacion del contador ----------
        // Se ganan partidas hasta pasar de 09 a 10 y hasta llegar a 99, que
        // son los dos puntos donde el contador en BCD puede fallar.
        while (wins !== 8'h09) ganar_partida;
        ganar_partida;
        check(wins === 8'h10, $sformatf("de 09 se paso a %02h en vez de 10", wins));

        while (wins !== 8'h99) ganar_partida;
        ganar_partida;
        check(wins === 8'h99, $sformatf("el contador no saturo y quedo en %02h", wins));

        $display("");
        if (errores == 0)
            $display("  PASS  reglas, prioridades, vencimiento diferido y contador correctos");
        else
            $display("  FAIL  %0d comprobaciones fallidas", errores);
        $display("");
        $finish;
    end

endmodule