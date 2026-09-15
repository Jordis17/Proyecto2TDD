// =====================================================================
// tb_top.sv - Prueba de integracion del sistema completo
//
// Aqui no hay modelos de nada del proyecto: se instancia el sistema
// entero y se le habla por donde se le habla en la tarjeta. Los botones
// se pulsan como pulsaria una persona, con el nivel mantenido el tiempo
// suficiente para pasar el filtro de rebotes, y la PC se sustituye por un
// par de tareas que meten y sacan bytes de la linea serie a la velocidad
// configurada.
//
// Lo que se observa son las patas del modulo LCD y la linea serie. El
// monitor del LCD reconstruye las dos filas siguiendo el cursor, igual
// que hace el controlador del display, de modo que lo que se compara es
// el texto que veria el jugador.
//
// Los tiempos van reducidos por parametro: el reloj sigue siendo el de
// 100 MHz en cuanto a la descripcion, pero el tick, los baudios y las
// esperas del LCD se acortan para que la simulacion sea viable. Los
// valores reales ya estan comprobados en los testbenches de cada modulo.
//
// La palabra secreta se lee por referencia jerarquica solo para decidir
// que letras mandar. Ninguna comprobacion se hace contra ella: todo lo
// que se verifica sale del LCD o de la linea serie.
//
// Comprueba:
//   1. al arrancar aparece la pantalla de seleccion, sin pulsar nada
//   2. BTN_SEL cambia el modo en el LCD
//   3. BTN_OK empieza la partida: el LCD muestra el patron y la PC recibe
//      START, PATT y ERR
//   4. una letra correcta revela en el LCD y llega como LET:X:OK
//   5. una letra incorrecta baja los intentos en las dos salidas
//   6. el sexto fallo termina la partida con END:LER y PERDISTE: FALLOS
//   7. el sistema vuelve solo a la pantalla de seleccion
//   8. los LEDs de estado acompanan cada etapa
// =====================================================================
`timescale 1ns/1ps

module tb_top;

    localparam int T_CLK    = 10;      // ns, reloj de 100 MHz
    localparam int TICK_CIC = 20;      // ciclos por tick, en vez de 100 000
    localparam int BAUD_DIV = 16;      // ciclos por bit, en vez de 868
    localparam int T_BIT    = BAUD_DIV * T_CLK;

    logic clk = 1'b0;
    logic btn_rst = 1'b0;
    logic btn_sel = 1'b0;
    logic btn_ok  = 1'b0;

    logic linea_rx = 1'b1;
    logic linea_tx;

    logic [7:0]  lcd_db;
    logic        lcd_rs, lcd_rw, lcd_e;
    logic [6:0]  seg;
    logic [7:0]  an;
    logic [15:0] led;
    logic        aud_pwm, aud_sd;

    int    errores = 0;
    string serie   = "";

    always #(T_CLK/2) clk = ~clk;

    top #(
        .TICK_CYCLES(TICK_CIC),
        .BAUD_DIV(BAUD_DIV),
        .DEBOUNCE_MS(2),
        .RESULT_MS(60),               // suficiente para poder mirar el resultado
        .TICKS_POR_SEGUNDO(100),        // un "segundo" son 2000 ciclos
        .LCD_POWERON_TICKS(2),
        .LCD_CIC_CORTA(20),
        .LCD_CIC_LARGA(40),
        .LCD_CIC_SETUP(3),
        .LCD_CIC_E_ALTO(3),
        .LCD_CIC_E_BAJO(3)
    ) dut (
        .clk_i(clk),
        .btn_rst_i(btn_rst), .btn_sel_i(btn_sel), .btn_ok_i(btn_ok),
        .uart_rx_i(linea_rx), .uart_tx_o(linea_tx),
        .lcd_db_o(lcd_db), .lcd_rs_o(lcd_rs), .lcd_rw_o(lcd_rw), .lcd_e_o(lcd_e),
        .seg_o(seg), .an_o(an), .led_o(led),
        .aud_pwm_o(aud_pwm), .aud_sd_o(aud_sd)
    );

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $display("  FAIL: %s", msg);
            errores++;
        end
    endtask

    // ---------------------------------------------------------------
    // Monitor del LCD: reconstruye las dos filas siguiendo el cursor
    // ---------------------------------------------------------------
    logic [7:0] pantalla [0:1][0:15];
    int fila_c = 0, col_c = 0;

    initial begin
        for (int f = 0; f < 2; f++)
            for (int c = 0; c < 16; c++) pantalla[f][c] = 8'h20;
    end

    always @(negedge lcd_e) begin
        if (lcd_rs === 1'b0) begin
            case (lcd_db)
                8'h80: begin fila_c = 0; col_c = 0; end
                8'hC0: begin fila_c = 1; col_c = 0; end
                8'h01, 8'h02: begin                 // limpiar y volver al inicio
                    if (lcd_db == 8'h01) begin
                        for (int f = 0; f < 2; f++)
                            for (int c = 0; c < 16; c++) pantalla[f][c] = 8'h20;
                    end
                    fila_c = 0;
                    col_c  = 0;
                end
                default: ;                          // comandos de configuracion
            endcase
        end else begin
            if (col_c < 16) pantalla[fila_c][col_c] = lcd_db;
            col_c++;
        end
    end

    function automatic string fila(input int f);
        string r;
        r = "";
        for (int c = 0; c < 16; c++) r = $sformatf("%s%c", r, pantalla[f][c]);
        return r;
    endfunction

    task automatic comprobar_lcd(input string l0, input string l1, input string nombre);
        if (fila(0) != l0 || fila(1) != l1) begin
            $display("  FAIL: %s", nombre);
            $display("        esperado [%s] [%s]", l0, l1);
            $display("        en el LCD [%s] [%s]", fila(0), fila(1));
            errores++;
        end
    endtask

    // ---------------------------------------------------------------
    // Linea serie
    // ---------------------------------------------------------------
    initial begin
        logic [7:0] b;
        forever begin
            @(negedge linea_tx);
            #(T_BIT/2);
            for (int i = 0; i < 8; i++) begin
                #(T_BIT);
                b[i] = linea_tx;
            end
            #(T_BIT);
            serie = $sformatf("%s%c", serie, b);
        end
    end

    task automatic mandar_letra(input logic [7:0] c);
        linea_rx = 1'b0;
        #(T_BIT);
        for (int i = 0; i < 8; i++) begin
            linea_rx = c[i];
            #(T_BIT);
        end
        linea_rx = 1'b1;
        #(T_BIT);
    endtask

    task automatic comprobar_serie(input string esperado, input string nombre);
        if (serie != esperado) begin
            $display("  FAIL: %s", nombre);
            $display("    --- esperado ---");
            $write("%s", esperado);
            $display("    --- recibido ---");
            $write("%s", serie);
            $display("    ----------------");
            errores++;
        end
    endtask

    // ---------------------------------------------------------------
    // Botones: se mantienen pulsados mas de lo que dura el filtro
    // ---------------------------------------------------------------
    task automatic pulsar_sel;
        btn_sel = 1'b1;
        repeat (TICK_CIC * 8) @(posedge clk);
        btn_sel = 1'b0;
        repeat (TICK_CIC * 8) @(posedge clk);
    endtask

    task automatic pulsar_ok;
        btn_ok = 1'b1;
        repeat (TICK_CIC * 8) @(posedge clk);
        btn_ok = 1'b0;
        repeat (TICK_CIC * 8) @(posedge clk);
    endtask

    // Espera a que el LCD y la linea serie lleven k ciclos sin moverse.
    // Hay que vigilar las dos: una trama tarda bastante mas que un
    // redibujado, y mirar solo el LCD dejaria la comparacion a medias.
    int ult_e = 0, ult_serie = 0, ciclo = 0;
    int n_e = 0, n_tx = 0;
    always @(posedge clk) ciclo++;
    always @(negedge lcd_e)    begin ult_e     = ciclo; n_e++;  end
    always @(negedge linea_tx) begin ult_serie = ciclo; n_tx++; end

    task automatic esperar_quieto(input int k);
        int inicio;
        inicio = ciclo;
        while (((ciclo - ult_e < k) || (ciclo - ult_serie < k)) &&
               (ciclo - inicio < 400000)) @(posedge clk);
        check(ciclo - inicio < 400000, "el sistema no se quedo quieto");
    endtask

    // Espera a que el sistema reaccione y despues a que termine. Sin la
    // primera mitad, una espera lanzada cuando todo ya estaba quieto
    // volveria de inmediato y se compararia antes de que hubiera
    // respuesta.
    task automatic esperar_respuesta(input int k);
        int e0, t0, guardia;
        e0 = n_e;
        t0 = n_tx;
        guardia = 0;
        while (n_e == e0 && n_tx == t0 && guardia < 200000) begin
            @(posedge clk);
            guardia++;
        end
        check(guardia < 200000, "el sistema no reacciono");
        esperar_quieto(k);
    endtask

    // ---------------------------------------------------------------
    // Letras: la palabra se consulta solo para elegir que mandar
    // ---------------------------------------------------------------
    function automatic logic [7:0] car_palabra(input int p);
        return dut.word_data[8*(12-1-p) +: 8];
    endfunction

    function automatic bit esta_en_palabra(input logic [7:0] c);
        for (int i = 0; i < 12; i++) begin
            if (i < int'(dut.word_len) && car_palabra(i) == c) return 1'b1;
        end
        return 1'b0;
    endfunction

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

    // patron esperado en el LCD: letra si esta revelada, guion si no
    function automatic string patron_lcd;
        string r;
        r = "";
        for (int i = 0; i < 16; i++) begin
            if (i < int'(dut.word_len))
                r = $sformatf("%s%c", r, dut.revealed[i] ? car_palabra(i) : 8'h5F);
            else
                r = $sformatf("%s ", r);
        end
        return r;
    endfunction

    function automatic string patron_serie;
        string r;
        r = "";
        for (int i = 0; i < int'(dut.word_len); i++)
            r = $sformatf("%s%c", r, dut.revealed[i] ? car_palabra(i) : 8'h5F);
        return r;
    endfunction

    // ---------------------------------------------------------------
    initial begin
        string   esperado;
        int      largo;
        logic [7:0] c;

        $display("");
        $display("=== tb_top ===");

        // ---------- 1: arranque sin tocar nada ----------
        esperar_quieto(TICK_CIC * 30);
        comprobar_lcd("AHORCADO  V:00  ", "MODO: FACIL     ", "pantalla de seleccion al arrancar");
        check(led[0] === 1'b1 && led[1] === 1'b0 && led[2] === 1'b0,
              "el LED de seleccion no esta encendido solo el");
        check(led[15] === 1'b0, "el LED de modo deberia estar apagado en facil");
        check(serie == "", "no debe mandarse nada a la PC en la seleccion");

        // ---------- 2: cambio de modo ----------
        pulsar_sel;
        esperar_respuesta(TICK_CIC * 30);
        comprobar_lcd("AHORCADO  V:00  ", "MODO: DIFICIL   ", "pantalla tras cambiar a dificil");
        check(led[15] === 1'b1, "el LED de modo deberia encenderse en dificil");
        pulsar_sel;
        esperar_respuesta(TICK_CIC * 30);
        comprobar_lcd("AHORCADO  V:00  ", "MODO: FACIL     ", "pantalla al volver a facil");

        // ---------- 3: comienzo de partida ----------
        serie = "";
        pulsar_ok;
        esperar_respuesta(TICK_CIC * 30);
        largo = int'(dut.word_len);
        check(largo >= 4, "la palabra es mas corta de lo que admite el banco");
        check(led[1] === 1'b1 && led[0] === 1'b0 && led[2] === 1'b0,
              "el LED de partida no esta encendido solo el");
        comprobar_lcd(patron_lcd(), "INTENTOS: 6    F", "pantalla de partida");
        esperado = $sformatf("START:F:%02d\nPATT:%s\nERR:6\n", largo, patron_serie());
        comprobar_serie(esperado, "aviso de comienzo");

        // ---------- 4: letra correcta ----------
        serie = "";
        c = car_palabra(0);
        mandar_letra(c);
        esperar_respuesta(TICK_CIC * 30);
        comprobar_lcd(patron_lcd(), "INTENTOS: 6    F", "pantalla tras acertar");
        esperado = $sformatf("LET:%c:OK \nPATT:%s\nERR:6\n", c, patron_serie());
        comprobar_serie(esperado, "aviso de letra acertada");
        check(dut.revealed[0] === 1'b1, "la posicion acertada no quedo revelada");

        // ---------- 5: letra incorrecta ----------
        serie = "";
        c = letra_ausente(0);
        mandar_letra(c);
        esperar_respuesta(TICK_CIC * 30);
        comprobar_lcd(patron_lcd(), "INTENTOS: 5    F", "pantalla tras fallar");
        esperado = $sformatf("LET:%c:NO \nPATT:%s\nERR:5\n", c, patron_serie());
        comprobar_serie(esperado, "aviso de letra fallada");

        // ---------- 6: sexto fallo ----------
        for (int i = 1; i < 5; i++) begin
            mandar_letra(letra_ausente(i));
            esperar_respuesta(TICK_CIC * 30);
        end
        comprobar_lcd(patron_lcd(), "INTENTOS: 1    F", "pantalla con un intento");

        serie = "";
        c = letra_ausente(5);
        mandar_letra(c);
        esperar_respuesta(TICK_CIC * 30);
        comprobar_lcd("PERDISTE: FALLOS", patron_serie_completo(),
                      "pantalla de derrota por fallos");
        esperado = $sformatf("LET:%c:NO \nPATT:%s\nERR:0\nEND:LER:%s\n",
                             c, patron_serie(), palabra_completa());
        comprobar_serie(esperado, "aviso de derrota por fallos");
        check(led[2] === 1'b1 && led[0] === 1'b0 && led[1] === 1'b0,
              "el LED de resultado no esta encendido solo el");

        // ---------- 7: vuelta sola a la seleccion ----------
        esperar_respuesta(TICK_CIC * 60);
        comprobar_lcd("AHORCADO  V:00  ", "MODO: FACIL     ", "vuelta a la seleccion");
        check(led[0] === 1'b1, "el LED de seleccion no volvio a encenderse");

        $display("");
        if (errores == 0)
            $display("  PASS  el sistema completo juega, pinta y conversa con la PC");
        else
            $display("  FAIL  %0d comprobaciones fallidas", errores);
        $display("");
        $finish;
    end

    // la palabra entera, para las comprobaciones del final de partida
    function automatic string palabra_completa;
        string r;
        r = "";
        for (int i = 0; i < int'(dut.word_len); i++) r = $sformatf("%s%c", r, car_palabra(i));
        return r;
    endfunction

    // la palabra completa rellenada a 16, como la pinta el LCD al perder
    function automatic string patron_serie_completo;
        string r;
        r = "";
        for (int i = 0; i < 16; i++) begin
            if (i < int'(dut.word_len)) r = $sformatf("%s%c", r, car_palabra(i));
            else                        r = $sformatf("%s ", r);
        end
        return r;
    endfunction

endmodule
