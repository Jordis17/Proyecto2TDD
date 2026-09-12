// =====================================================================
// Se instancia el DUT con parametros de tiempo reducidos (pero distintos
// entre si) para poder simular en segundos y aun asi distinguir espera
// "corta" de espera "larga". Se usa dut.st_q solo para saber CUANDO
// mirar, nunca para decidir si algo paso o no: lo que se compara contra
// el valor esperado son siempre las salidas del puerto (lcd_db_o,
// lcd_e_o, busy_o, done_o, etc.).
//
// Cubre:
//   - Secuencia de arranque completa: los 4 comandos en orden, con rs=0,
//     y la espera larga en el paso de Clear Display.
//   - busy_o en alto durante todo el arranque y done_o sin pulsar nunca
//     en ese tramo.
//   - Operacion normal iniciada por start_i: dato/rs correctos en el
//     bus, pulso de E, done_o de un ciclo al terminar.
//   - necesita_larga: clear (0x01) y home (0x02) en comando piden la
//     espera larga; un dato normal (rs=1) con el mismo valor 0x01 NO la
//     pide.
//   - rst_i no afecta el arranque (documentado: solo actua si init_q=1)
//     y si aborta una operacion normal en curso.
// =====================================================================
`timescale 1ns/1ps

module tb_lcd_controller;

    localparam int CLK_PERIOD   = 10;
    localparam int POWERON_TICKS = 3;
    localparam int CIC_CORTA    = 20;
    localparam int CIC_LARGA    = 50;
    localparam int CIC_SETUP    = 4;
    localparam int CIC_E_ALTO   = 4;
    localparam int CIC_E_BAJO   = 4;

    logic clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    logic       rst;
    logic       tick;
    logic       start_i, rs_i;
    logic [7:0] data_i;
    logic       busy_o, done_o;
    logic [7:0] lcd_db_o;
    logic       lcd_rs_o, lcd_rw_o, lcd_e_o;

    int errcnt = 0;
    int checks = 0;

    lcd_controller #(
        .POWERON_TICKS (POWERON_TICKS),
        .CIC_CORTA     (CIC_CORTA),
        .CIC_LARGA     (CIC_LARGA),
        .CIC_SETUP     (CIC_SETUP),
        .CIC_E_ALTO    (CIC_E_ALTO),
        .CIC_E_BAJO    (CIC_E_BAJO)
    ) dut (
        .clk_i    (clk),
        .rst_i    (rst),
        .tick_i   (tick),
        .start_i  (start_i),
        .rs_i     (rs_i),
        .data_i   (data_i),
        .busy_o   (busy_o),
        .done_o   (done_o),
        .lcd_db_o (lcd_db_o),
        .lcd_rs_o (lcd_rs_o),
        .lcd_rw_o (lcd_rw_o),
        .lcd_e_o  (lcd_e_o)
    );

    // pulso de "1 ms" simplificado: un ciclo de clk_i cada 4 ciclos
    initial begin
        tick = 1'b0;
        forever begin
            repeat (4) @(posedge clk);
            tick <= 1'b1;
            @(posedge clk);
            tick <= 1'b0;
        end
    end

    task automatic check(string etiqueta, logic [31:0] got, logic [31:0] exp);
        checks++;
        if (got !== exp) begin
            errcnt++;
            $display("[FALLO] %s: esperado=0x%0h obtenido=0x%0h", etiqueta, exp, got);
        end
    endtask

    // espera un pulso de E completo y devuelve si la espera fue "larga"
    // midiendo cuantos ciclos paso en S_ESPERA (blackbox: solo cuenta
    // ciclos con busy_o=1 y lcd_e_o=0 despues del flanco de bajada de E).
    task automatic medir_espera(output int ciclos);
        ciclos = 0;
        @(negedge lcd_e_o);   // paso a S_E_BAJO -> S_ESPERA
        // avanzar hasta que busy_o caiga o vuelva a subir E (proxima operacion)
        while (busy_o && !done_o) begin
            @(posedge clk);
            ciclos++;
            if (ciclos > 1000) begin
                $display("[FALLO] medir_espera: tiempo de espera nunca termino");
                errcnt++; checks++;
                break;
            end
        end
    endtask

    initial begin
        int espera_medida;

        rst = 1'b0; start_i = 1'b0; rs_i = 1'b0; data_i = 8'h00;
        repeat (2) @(posedge clk);

        // ---------------- secuencia de arranque ----------------
        // Paso 1: Function Set 0x38, rs=0, espera corta.
        @(posedge lcd_e_o);
        check("arranque paso1 dato = Function Set", lcd_db_o, 8'h38);
        check("arranque paso1 rs = 0",               lcd_rs_o, 1'b0);
        check("busy_o en alto durante el arranque",  busy_o,   1'b1);
        medir_espera(espera_medida);
        check("arranque paso1 espera CORTA", (espera_medida >= CIC_CORTA-2 && espera_medida <= CIC_CORTA+2), 1'b1);

        // Paso 2: Display On/Off 0x0C, espera corta.
        @(posedge lcd_e_o);
        check("arranque paso2 dato = Display On/Off", lcd_db_o, 8'h0C);
        medir_espera(espera_medida);
        check("arranque paso2 espera CORTA", (espera_medida >= CIC_CORTA-2 && espera_medida <= CIC_CORTA+2), 1'b1);

        // Paso 3: Clear Display 0x01, espera LARGA.
        @(posedge lcd_e_o);
        check("arranque paso3 dato = Clear Display", lcd_db_o, 8'h01);
        medir_espera(espera_medida);
        check("arranque paso3 espera LARGA", (espera_medida >= CIC_LARGA-2 && espera_medida <= CIC_LARGA+2), 1'b1);

        // Paso 4: Entry Mode 0x06, espera corta. Tras esto, IDLE.
        @(posedge lcd_e_o);
        check("arranque paso4 dato = Entry Mode", lcd_db_o, 8'h06);
        check("done_o no pulsa durante el arranque", done_o, 1'b0);

        // Esperar a que quede IDLE (busy_o baja) sin que haya pulsado done_o.
        wait (busy_o == 1'b0);
        #1;
        check("tras arranque: busy_o en 0", busy_o, 1'b0);
        check("tras arranque: done_o en 0 (nunca pulso)", done_o, 1'b0);

        // ---------------- operacion normal: escribir un caracter ----------------
        data_i  = 8'h41;   // 'A'
        rs_i    = 1'b1;    // dato, no comando
        @(negedge clk);
        start_i = 1'b1;
        @(posedge clk);
        #1;
        start_i = 1'b0;
        check("busy_o sube al aceptar start_i", busy_o, 1'b1);

        @(posedge lcd_e_o);
        check("operacion normal: dato en el bus", lcd_db_o,  8'h41);
        check("operacion normal: rs en el bus",   lcd_rs_o,  1'b1);
        check("lcd_rw_o siempre en 0",             lcd_rw_o,  1'b0);

        medir_espera(espera_medida);
        check("dato normal (rs=1) usa espera CORTA aunque valga 0x01",
              (espera_medida >= CIC_CORTA-2 && espera_medida <= CIC_CORTA+2), 1'b1);

        // done_o debe pulsar exactamente un ciclo al terminar
        wait (done_o == 1'b1);
        check("busy_o baja junto con done_o", busy_o, 1'b0);
        @(posedge clk); #1;
        check("done_o vuelve a 0 el ciclo siguiente", done_o, 1'b0);

        // ---------------- necesita_larga: comando 0x01 (rs=0) ----------------
        data_i = 8'h01; rs_i = 1'b0;
        @(negedge clk); start_i = 1'b1; @(posedge clk); #1; start_i = 1'b0;
        @(posedge lcd_e_o);
        medir_espera(espera_medida);
        check("comando 0x01 (rs=0) pide espera LARGA",
              (espera_medida >= CIC_LARGA-2 && espera_medida <= CIC_LARGA+2), 1'b1);
        wait (done_o == 1'b1); @(posedge clk); #1;

        // ---------------- necesita_larga: comando 0x02 (home, rs=0) ----------------
        data_i = 8'h02; rs_i = 1'b0;
        @(negedge clk); start_i = 1'b1; @(posedge clk); #1; start_i = 1'b0;
        @(posedge lcd_e_o);
        medir_espera(espera_medida);
        check("comando 0x02 (home, rs=0) pide espera LARGA",
              (espera_medida >= CIC_LARGA-2 && espera_medida <= CIC_LARGA+2), 1'b1);
        wait (done_o == 1'b1); @(posedge clk); #1;

        // ---------------- rst_i aborta una operacion en curso ----------------
        data_i = 8'h55; rs_i = 1'b1;
        @(negedge clk); start_i = 1'b1; @(posedge clk); #1; start_i = 1'b0;
        @(posedge lcd_e_o);   // a mitad de la transaccion
        @(negedge clk);
        rst = 1'b1;
        @(posedge clk);
        #1;
        check("rst_i en operacion normal: busy_o cae de inmediato", busy_o, 1'b0);
        check("rst_i en operacion normal: lcd_e_o cae de inmediato", lcd_e_o, 1'b0);
        rst = 1'b0;

        $display("----------------------------------------------------");
        if (errcnt == 0)
            $display("PASA: lcd_controller (%0d verificaciones)", checks);
        else
            $display("FALLA: lcd_controller (%0d de %0d verificaciones fallaron)",
                      errcnt, checks);
        $display("----------------------------------------------------");
        $finish;
    end

    // salvavidas: si algo se cuelga esperando un evento que nunca llega
    initial begin
        #2_000_000;
        $display("[FALLO] TIMEOUT GLOBAL: la simulacion no termino a tiempo");
        errcnt++;
        $display("FALLA: lcd_controller (timeout)");
        $finish;
    end

endmodule
