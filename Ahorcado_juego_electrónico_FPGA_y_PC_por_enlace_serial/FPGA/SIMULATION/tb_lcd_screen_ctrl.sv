// =====================================================================
// tb_lcd_screen_ctrl.sv - Testbench de integracion autoverificable
//
// lcd_screen_ctrl no tiene sentido probarlo solo: su trabajo es dialogar
// por el bus con lcd_peripheral, que a su vez maneja lcd_controller. Este
// testbench arma la cadena completa (screen_ctrl -> peripheral ->
// controller) con los tiempos del controller reducidos por parametro
// (mismo mecanismo que usa el equipo, solo que con numeros mas chicos
// para simular rapido), y verifica del lado fisico del LCD (lcd_db_o,
// lcd_rs_o, capturados en el flanco de bajada de lcd_e_o, que es cuando
// el HD44780 realmente lee el dato) que salen los 34 bytes esperados,
// en el orden esperado, para dos pantallas distintas.
//
// Los valores esperados de cada pantalla se calculan a mano en este
// archivo (no se copian del RTL de lcd_text_gen), a partir de las
// cadenas literales documentadas en ese modulo.
//
// Tambien verifica que la maquina no arranca un redibujado mientras el
// periferico este ocupado (lo hereda gratis del arranque real del LCD:
// si redraw_i llegara antes de terminar la secuencia de encendido, el
// primer intento de escritura se quedaria esperando en S_LIBRE).
// =====================================================================
`timescale 1ns/1ps

module tb_lcd_screen_ctrl;

    import lcd_screen_pkg::SCR_PLAY, lcd_screen_pkg::SCR_WIN;

    localparam int MAX_LEN = 12;
    localparam int CLK_PERIOD = 10;

    // tiempos reducidos solo para simular rapido
    localparam int POWERON_TICKS = 2;
    localparam int CIC_CORTA     = 10;
    localparam int CIC_LARGA     = 20;
    localparam int CIC_SETUP     = 2;
    localparam int CIC_E_ALTO    = 2;
    localparam int CIC_E_BAJO    = 2;

    logic clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    logic rst;
    logic tick;

    // puerto de lcd_screen_ctrl
    logic [2:0]            screen_i;
    logic                  redraw_i;
    logic                  busy_o;
    logic [8*MAX_LEN-1:0]  word_data_i;
    logic [3:0]            word_len_i;
    logic [MAX_LEN-1:0]    revealed_i;
    logic [2:0]            errors_i;
    logic                  mode_i;
    logic [7:0]            wins_i;

    // bus interno screen_ctrl <-> peripheral
    logic        we;
    logic [1:0]  addr;
    logic [31:0] wdata;
    logic [31:0] rdata;

    // interno peripheral <-> controller
    logic        p_start, p_rs, p_busy, p_done;
    logic [7:0]  p_data;

    // pines fisicos del LCD
    logic [7:0] lcd_db_o;
    logic       lcd_rs_o, lcd_rw_o, lcd_e_o;

    int errcnt = 0;
    int checks = 0;

    lcd_screen_ctrl #(.MAX_LEN(MAX_LEN)) u_ctrl (
        .clk_i        (clk),
        .rst_i        (rst),
        .screen_i     (screen_i),
        .redraw_i     (redraw_i),
        .busy_o       (busy_o),
        .word_data_i  (word_data_i),
        .word_len_i   (word_len_i),
        .revealed_i   (revealed_i),
        .errors_i     (errors_i),
        .mode_i       (mode_i),
        .wins_i       (wins_i),
        .write_enable_o (we),
        .addr_o         (addr),
        .wdata_o        (wdata),
        .rdata_i        (rdata)
    );

    lcd_peripheral u_periph (
        .clk_i          (clk),
        .rst_i          (rst),
        .write_enable_i (we),
        .addr_i         (addr),
        .wdata_i        (wdata),
        .rdata_o        (rdata),
        .start_o        (p_start),
        .rs_o           (p_rs),
        .data_o         (p_data),
        .busy_i         (p_busy),
        .done_i         (p_done)
    );

    lcd_controller #(
        .POWERON_TICKS (POWERON_TICKS),
        .CIC_CORTA     (CIC_CORTA),
        .CIC_LARGA     (CIC_LARGA),
        .CIC_SETUP     (CIC_SETUP),
        .CIC_E_ALTO    (CIC_E_ALTO),
        .CIC_E_BAJO    (CIC_E_BAJO)
    ) u_lcdctrl (
        .clk_i    (clk),
        .rst_i    (rst),
        .tick_i   (tick),
        .start_i  (p_start),
        .rs_i     (p_rs),
        .data_i   (p_data),
        .busy_o   (p_busy),
        .done_o   (p_done),
        .lcd_db_o (lcd_db_o),
        .lcd_rs_o (lcd_rs_o),
        .lcd_rw_o (lcd_rw_o),
        .lcd_e_o  (lcd_e_o)
    );

    // "1 ms" simplificado
    initial begin
        tick = 1'b0;
        forever begin
            repeat (4) @(posedge clk);
            tick <= 1'b1;
            @(posedge clk);
            tick <= 1'b0;
        end
    end

    // captura cada byte tal como lo veria el HD44780 (flanco de bajada de E)
    typedef struct packed { logic [7:0] b; logic rs; } trans_t;
    trans_t captured[$];

    always @(negedge lcd_e_o) captured.push_back('{b: lcd_db_o, rs: lcd_rs_o});

    task automatic check(string etiqueta, logic [63:0] got, logic [63:0] exp);
        checks++;
        if (got !== exp) begin
            errcnt++;
            $display("[FALLO] %s: esperado=0x%0h obtenido=0x%0h", etiqueta, exp, got);
        end
    endtask

    task automatic check_secuencia(string etiqueta, ref trans_t golden[34]);
        checks++;
        if (captured.size() != 34) begin
            errcnt++;
            $display("[FALLO] %s: se esperaban 34 transacciones, llegaron %0d",
                      etiqueta, captured.size());
        end else begin
            int fallos_locales = 0;
            for (int i = 0; i < 34; i++) begin
                if (captured[i].b !== golden[i].b || captured[i].rs !== golden[i].rs) begin
                    fallos_locales++;
                    $display("[FALLO] %s paso %0d: esperado byte=0x%02h rs=%0b -- obtenido byte=0x%02h rs=%0b",
                              etiqueta, i, golden[i].b, golden[i].rs, captured[i].b, captured[i].rs);
                end
            end
            if (fallos_locales > 0) errcnt++;
        end
    endtask

    initial begin
        trans_t golden_play[34];
        trans_t golden_win[34];

        // ---- pantalla SCR_PLAY: palabra "GATO", G y T reveladas, 2 errores, dificil, wins=0x34 ----
        golden_play[0]  = '{b: 8'h80, rs: 1'b0};
        golden_play[1]  = '{b: 8'h47, rs: 1'b1};  // patron col0: 'G' revelado
        golden_play[2]  = '{b: 8'h5F, rs: 1'b1};  // col1 oculto '_'
        golden_play[3]  = '{b: 8'h54, rs: 1'b1};  // col2: 'T' revelado
        golden_play[4]  = '{b: 8'h5F, rs: 1'b1};  // col3 oculto '_'
        for (int p = 5; p <= 16; p++) golden_play[p] = '{b: 8'h20, rs: 1'b1}; // paso5..16 = col4..15 vacio
        golden_play[17] = '{b: 8'hC0, rs: 1'b0};
        golden_play[18] = '{b: 8'h49, rs: 1'b1}; // 'I'
        golden_play[19] = '{b: 8'h4E, rs: 1'b1}; // 'N'
        golden_play[20] = '{b: 8'h54, rs: 1'b1}; // 'T'
        golden_play[21] = '{b: 8'h45, rs: 1'b1}; // 'E'
        golden_play[22] = '{b: 8'h4E, rs: 1'b1}; // 'N'
        golden_play[23] = '{b: 8'h54, rs: 1'b1}; // 'T'
        golden_play[24] = '{b: 8'h4F, rs: 1'b1}; // 'O'
        golden_play[25] = '{b: 8'h53, rs: 1'b1}; // 'S'
        golden_play[26] = '{b: 8'h3A, rs: 1'b1}; // ':'
        golden_play[27] = '{b: 8'h20, rs: 1'b1}; // ' '
        golden_play[28] = '{b: 8'h34, rs: 1'b1}; // '4' (intentos = 6-2)
        golden_play[29] = '{b: 8'h20, rs: 1'b1};
        golden_play[30] = '{b: 8'h20, rs: 1'b1};
        golden_play[31] = '{b: 8'h20, rs: 1'b1};
        golden_play[32] = '{b: 8'h20, rs: 1'b1};
        golden_play[33] = '{b: 8'h44, rs: 1'b1}; // 'D' modo dificil

        // ---- pantalla SCR_WIN: misma palabra, nada revelado (se debe ver completa igual) ----
        golden_win[0]  = '{b: 8'h80, rs: 1'b0};
        golden_win[1]  = '{b: 8'h20, rs: 1'b1};
        golden_win[2]  = '{b: 8'h20, rs: 1'b1};
        golden_win[3]  = '{b: 8'h20, rs: 1'b1};
        golden_win[4]  = '{b: 8'h47, rs: 1'b1}; // 'G'
        golden_win[5]  = '{b: 8'h41, rs: 1'b1}; // 'A'
        golden_win[6]  = '{b: 8'h4E, rs: 1'b1}; // 'N'
        golden_win[7]  = '{b: 8'h41, rs: 1'b1}; // 'A'
        golden_win[8]  = '{b: 8'h53, rs: 1'b1}; // 'S'
        golden_win[9]  = '{b: 8'h54, rs: 1'b1}; // 'T'
        golden_win[10] = '{b: 8'h45, rs: 1'b1}; // 'E'
        golden_win[11] = '{b: 8'h21, rs: 1'b1}; // '!'
        for (int p = 12; p <= 16; p++) golden_win[p] = '{b: 8'h20, rs: 1'b1}; // paso12..16 = col11..15 vacio
        golden_win[17] = '{b: 8'hC0, rs: 1'b0};
        golden_win[18] = '{b: 8'h47, rs: 1'b1}; // 'G' (revelado siempre, no depende de revealed_i)
        golden_win[19] = '{b: 8'h41, rs: 1'b1}; // 'A'
        golden_win[20] = '{b: 8'h54, rs: 1'b1}; // 'T'
        golden_win[21] = '{b: 8'h4F, rs: 1'b1}; // 'O'
        for (int c = 22; c <= 33; c++) golden_win[c] = '{b: 8'h20, rs: 1'b1};

        rst = 1'b1; redraw_i = 1'b0;
        screen_i = SCR_PLAY; word_data_i = '0; word_len_i = 4'd0;
        revealed_i = '0; errors_i = 3'd0; mode_i = 1'b0; wins_i = 8'h00;
        repeat (3) @(posedge clk);
        rst = 1'b0;

        // esperar a que termine el arranque real del LCD antes de pedir nada
        wait (p_busy == 1'b0);
        repeat (2) @(posedge clk);

        // ---------------- primera pantalla: SCR_PLAY ----------------
        screen_i    = SCR_PLAY;
        word_data_i = {"GATO", 64'd0};
        word_len_i  = 4'd4;
        revealed_i  = 12'b0000_0000_0101;
        errors_i    = 3'd2;
        mode_i      = 1'b1;
        wins_i      = 8'h34;

        captured.delete();
        @(negedge clk);
        redraw_i = 1'b1;
        @(posedge clk);
        #1;
        redraw_i = 1'b0;
        check("busy_o sube al aceptar redraw_i", busy_o, 1'b1);

        wait (busy_o == 1'b0);
        #1;
        check_secuencia("SCR_PLAY", golden_play);

        // ---------------- segunda pantalla: SCR_WIN, palabra sin revelar ----------------
        screen_i   = SCR_WIN;
        revealed_i = '0;
        repeat (2) @(posedge clk);

        captured.delete();
        @(negedge clk);
        redraw_i = 1'b1;
        @(posedge clk);
        #1;
        redraw_i = 1'b0;

        wait (busy_o == 1'b0);
        #1;
        check_secuencia("SCR_WIN", golden_win);

        // ---------------- una orden que llega con busy_o=1 se ignora ----------------
        screen_i = SCR_PLAY;
        captured.delete();
        @(negedge clk);
        redraw_i = 1'b1;
        @(posedge clk); #1;
        redraw_i = 1'b0;
        check("segundo redraw_i: busy_o sube", busy_o, 1'b1);
        // intento de un tercer redraw_i mientras el segundo sigue en curso
        @(negedge clk);
        redraw_i = 1'b1;
        @(posedge clk); #1;
        redraw_i = 1'b0;
        check("redraw_i durante busy_o=1 no reinicia el conteo (sigue en curso)", busy_o, 1'b1);
        wait (busy_o == 1'b0);
        #1;
        check("tras ignorar el redraw_i intruso, la secuencia igual completa 34 pasos",
              captured.size(), 34);

        $display("----------------------------------------------------");
        if (errcnt == 0)
            $display("PASA: lcd_screen_ctrl (integracion) (%0d verificaciones)", checks);
        else
            $display("FALLA: lcd_screen_ctrl (integracion) (%0d de %0d verificaciones fallaron)",
                      errcnt, checks);
        $display("----------------------------------------------------");
        $finish;
    end

    initial begin
        #5_000_000;
        $display("[FALLO] TIMEOUT GLOBAL: la simulacion no termino a tiempo");
        $display("FALLA: lcd_screen_ctrl (timeout)");
        $finish;
    end

endmodule
