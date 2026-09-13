// =====================================================================
// tb_uart_msg.sv - Testbench autoverificable de la capa de protocolo
//
// Se prueba la cadena completa: capa de protocolo, periferico y modelo
// del nucleo. El monitor no mira senales internas: se engancha a la
// linea serie y decodifica la trama bit a bit, muestreando en el centro
// de cada bit, igual que haria la PC. Lo que se compara es la cadena de
// texto que sale por el cable.
//
// El modelo del nucleo no es el nucleo del curso. Cuando llegue el real
// se repite esta misma bateria y se comparan los resultados.
//
// Comprueba:
//   1. el evento de inicio emite START, PATT y ERR con sus separadores
//   2. la longitud sale con dos digitos, tanto por debajo como por
//      encima de diez
//   3. una letra acertada emite OK y una fallada NO, ambos de tres
//      caracteres
//   4. una letra repetida emite solo la linea RPT
//   5. los tres desenlaces salen con la palabra completa
//   6. el patron lleva tantos caracteres como letras tenga la palabra
//   7. los intentos que se informan son los que quedan, no los errores
//   8. cada linea termina en salto de linea y no se emite nada de mas
//   9. un evento que llega durante un envio se ignora
//  10. los datos se copian al empezar: cambiarlos a mitad no altera la
//      trama en curso
//  11. una letra recibida sale por rx_valid con el codigo correcto
//  12. un byte que no es una letra se descarta y deja el aviso limpio,
//      de modo que la letra siguiente si llega
//  13. un byte recibido durante una transmision se atiende al terminar
// =====================================================================
`timescale 1ns/1ps

module tb_uart_msg;

    localparam int MAX_LEN  = 12;
    localparam int BAUD_DIV = 16;             // reducido para simular rapido
    localparam int T_CLK    = 10;             // ns
    localparam int T_BIT    = BAUD_DIV * T_CLK;

    localparam logic [1:0] EV_INICIO   = 2'd0;
    localparam logic [1:0] EV_LETRA    = 2'd1;
    localparam logic [1:0] EV_REPETIDA = 2'd2;
    localparam logic [1:0] EV_FIN      = 2'd3;

    localparam logic [1:0] FIN_WIN = 2'd0;
    localparam logic [1:0] FIN_LER = 2'd1;
    localparam logic [1:0] FIN_LTO = 2'd2;

    localparam logic [8*MAX_LEN-1:0] W_TECLADO    = "TECLADO     ";
    localparam logic [8*MAX_LEN-1:0] W_VENTILADOR = "VENTILADOR  ";

    logic clk = 1'b0;
    logic rst = 1'b0;

    logic [1:0] evento  = EV_INICIO;
    logic       lanzar  = 1'b0;
    logic       busy_m;
    logic [7:0] rx_letra;
    logic       rx_ok;

    logic [7:0]           letra   = "A";
    logic                 acierto = 1'b0;
    logic [1:0]           fin_cod = FIN_WIN;
    logic [8*MAX_LEN-1:0] wdata_w = W_TECLADO;
    logic [3:0]           wlen    = 4'd7;
    logic [MAX_LEN-1:0]   rev     = '0;
    logic [2:0]           errores_j = 3'd0;
    logic                 modo    = 1'b0;

    logic        we;
    logic [1:0]  addr;
    logic [31:0] wdata, rdata;

    logic [7:0] tx_data;
    logic       tx_start, tx_busy;
    logic [7:0] rx_data;
    logic       rx_valid;
    logic       linea_tx;
    logic       linea_rx = 1'b1;      // en reposo

    int    errores = 0;
    int    n_rx    = 0;
    logic [7:0] ult_rx = 8'h00;
    string recibido = "";

    always #(T_CLK/2) clk = ~clk;

    uart_msg #(.MAX_LEN(MAX_LEN)) dut (
        .clk_i(clk), .rst_i(rst),
        .event_i(evento), .send_i(lanzar), .busy_o(busy_m),
        .rx_letter_o(rx_letra), .rx_valid_o(rx_ok),
        .letter_i(letra), .hit_i(acierto), .end_code_i(fin_cod),
        .word_data_i(wdata_w), .word_len_i(wlen), .revealed_i(rev),
        .errors_i(errores_j), .mode_i(modo),
        .write_enable_o(we), .addr_o(addr), .wdata_o(wdata), .rdata_i(rdata)
    );

    uart_peripheral periferico (
        .clk_i(clk), .rst_i(rst),
        .write_enable_i(we), .addr_i(addr), .wdata_i(wdata), .rdata_o(rdata),
        .tx_data_o(tx_data), .tx_start_o(tx_start), .tx_busy_i(tx_busy),
        .rx_data_i(rx_data), .rx_valid_i(rx_valid)
    );

    uart_core_model #(.BAUD_DIV(BAUD_DIV)) nucleo (
        .clk_i(clk), .rst_i(rst),
        .tx_o(linea_tx), .rx_i(linea_rx),
        .tx_data_i(tx_data), .tx_start_i(tx_start), .tx_busy_o(tx_busy),
        .rx_data_o(rx_data), .rx_valid_o(rx_valid)
    );

    // anota cada letra que la capa entrega hacia arriba
    always @(posedge clk) begin
        if (rx_ok) begin
            ult_rx = rx_letra;
            n_rx++;
        end
    end

    // manda un byte por la linea de entrada, como haria la PC
    task automatic mandar_byte(input logic [7:0] b);
        linea_rx = 1'b0;                 // arranque
        #(T_BIT);
        for (int i = 0; i < 8; i++) begin
            linea_rx = b[i];             // el menos significativo primero
            #(T_BIT);
        end
        linea_rx = 1'b1;                 // parada
        #(T_BIT);
    endtask

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $display("  FAIL: %s", msg);
            errores++;
        end
    endtask

    // ---- receptor de la linea serie ----
    // Muestrea en el centro de cada bit, como lo haria la PC.
    initial begin
        logic [7:0] b;
        forever begin
            @(negedge linea_tx);           // bit de arranque
            #(T_BIT/2);                    // centro del arranque
            for (int i = 0; i < 8; i++) begin
                #(T_BIT);
                b[i] = linea_tx;           // el menos significativo primero
            end
            #(T_BIT);                      // centro del bit de parada
            if (linea_tx !== 1'b1) begin
                $display("  FAIL: bit de parada incorrecto en 0x%02h", b);
                errores++;
            end
            recibido = {recibido, string'(b)};
        end
    end

    task automatic emitir(input logic [1:0] ev);
        int guardia;
        @(negedge clk);
        evento   = ev;
        recibido = "";
        lanzar   = 1'b1;
        @(negedge clk);
        lanzar   = 1'b0;
        check(busy_m === 1'b1, "la capa no se declaro ocupada al aceptar el evento");
        guardia = 0;
        while (busy_m && guardia < 200000) begin
            @(posedge clk);
            guardia++;
        end
        check(guardia < 200000, "el envio no termino nunca");
        // margen para que el ultimo byte acabe de salir por la linea
        #(T_BIT * 12);
    endtask

    task automatic comparar(input string esperado, input string nombre);
        if (recibido != esperado) begin
            // Las tramas llevan saltos de linea propios, asi que se
            // imprimen tal cual: cada linea del protocolo cae en una
            // linea de la salida.
            $display("  FAIL: %s", nombre);
            $display("    --- esperado ---");
            $write("%s", esperado);
            $display("    --- obtenido ---");
            $write("%s", recibido);
            $display("    ----------------");
            errores++;
        end
    endtask

    initial begin
        int n_antes;
        $display("");
        $display("=== tb_uart_msg ===");

        repeat (4) @(negedge clk);
        check(busy_m === 1'b0, "la capa deberia arrancar libre");

        // ---------- 1: inicio de partida ----------
        wdata_w   = W_TECLADO;
        wlen      = 4'd7;
        rev       = '0;
        errores_j = 3'd0;
        modo      = 1'b0;
        emitir(EV_INICIO);
        comparar("START:F:07\nPATT:_______\nERR:6\n", "inicio en facil");

        // ---------- 2: longitud de dos digitos y modo dificil ----------
        wdata_w = W_VENTILADOR;
        wlen    = 4'd10;
        modo    = 1'b1;
        emitir(EV_INICIO);
        comparar("START:D:10\nPATT:__________\nERR:6\n", "inicio con palabra de diez");

        // ---------- 3: letra acertada ----------
        wdata_w   = W_TECLADO;
        wlen      = 4'd7;
        modo      = 1'b0;
        rev       = 12'b0000_0000_0001;   // revelada la primera posicion
        errores_j = 3'd0;
        letra     = "T";
        acierto   = 1'b1;
        emitir(EV_LETRA);
        comparar("LET:T:OK \nPATT:T______\nERR:6\n", "letra acertada");

        // ---------- 3b: letra fallada ----------
        errores_j = 3'd1;
        letra     = "Z";
        acierto   = 1'b0;
        emitir(EV_LETRA);
        comparar("LET:Z:NO \nPATT:T______\nERR:5\n", "letra fallada");

        // ---------- 7: los intentos son los que quedan ----------
        errores_j = 3'd6;
        letra     = "Q";
        acierto   = 1'b0;
        rev       = 12'b0000_0000_1001;
        emitir(EV_LETRA);
        comparar("LET:Q:NO \nPATT:T__L___\nERR:0\n", "sin intentos restantes");

        // ---------- 4: letra repetida ----------
        letra   = "T";
        acierto = 1'b1;                  // no debe influir en una repetida
        emitir(EV_REPETIDA);
        comparar("LET:T:RPT\n", "letra repetida");

        // ---------- 5: los tres desenlaces ----------
        fin_cod = FIN_WIN;
        emitir(EV_FIN);
        comparar("END:WIN:TECLADO\n", "victoria");

        fin_cod = FIN_LER;
        emitir(EV_FIN);
        comparar("END:LER:TECLADO\n", "derrota por fallos");

        fin_cod = FIN_LTO;
        emitir(EV_FIN);
        comparar("END:LTO:TECLADO\n", "derrota por tiempo");

        // el desenlace con la palabra larga, para ver el ancho variable
        wdata_w = W_VENTILADOR;
        wlen    = 4'd10;
        fin_cod = FIN_WIN;
        emitir(EV_FIN);
        comparar("END:WIN:VENTILADOR\n", "victoria con palabra larga");

        // ---------- 9: evento durante un envio ----------
        wdata_w   = W_TECLADO;
        wlen      = 4'd7;
        rev       = '0;
        errores_j = 3'd0;
        modo      = 1'b0;
        @(negedge clk);
        evento   = EV_INICIO;
        recibido = "";
        lanzar   = 1'b1;
        @(negedge clk);
        lanzar   = 1'b0;
        repeat (8 * BAUD_DIV * 10) @(negedge clk);   // ya va por media trama
        check(busy_m === 1'b1, "hacia falta que estuviera transmitiendo");
        evento = EV_FIN;
        lanzar = 1'b1;
        @(negedge clk);
        lanzar = 1'b0;
        while (busy_m) @(posedge clk);
        #(T_BIT * 12);
        comparar("START:F:07\nPATT:_______\nERR:6\n", "evento ignorado durante el envio");

        // ---------- 10: los datos se copian al empezar ----------
        rev       = 12'b0000_0000_1001;
        errores_j = 3'd2;
        letra     = "L";
        acierto   = 1'b1;
        @(negedge clk);
        evento   = EV_LETRA;
        recibido = "";
        lanzar   = 1'b1;
        @(negedge clk);
        lanzar   = 1'b0;
        repeat (5 * BAUD_DIV * 10) @(negedge clk);
        // cambio brusco de todo a mitad de la trama
        wdata_w   = W_VENTILADOR;
        wlen      = 4'd10;
        rev       = 12'b1111_1111_1111;
        errores_j = 3'd6;
        letra     = "X";
        acierto   = 1'b0;
        modo      = 1'b1;
        while (busy_m) @(posedge clk);
        #(T_BIT * 12);
        comparar("LET:L:OK \nPATT:T__L___\nERR:4\n", "datos copiados al empezar");

        // ---------- 11: recepcion de una letra ----------
        n_rx = 0;
        mandar_byte("H");
        repeat (40) @(negedge clk);
        check(n_rx == 1, $sformatf("se esperaba una letra recibida y hubo %0d", n_rx));
        check(ult_rx == "H", $sformatf("llego 0x%02h en vez de la H", ult_rx));

        // ---------- 12: un byte que no es letra se descarta ----------
        n_rx = 0;
        mandar_byte("7");                 // digito, no letra
        repeat (40) @(negedge clk);
        check(n_rx == 0, "un byte que no es letra no deberia salir hacia arriba");
        mandar_byte("a");                 // minuscula, tampoco
        repeat (40) @(negedge clk);
        check(n_rx == 0, "una minuscula no deberia salir hacia arriba");
        // si el aviso quedo limpio, la siguiente letra si tiene que llegar
        mandar_byte("Q");
        repeat (40) @(negedge clk);
        check(n_rx == 1, "tras un byte descartado la letra siguiente no llego");
        check(ult_rx == "Q", $sformatf("llego 0x%02h en vez de la Q", ult_rx));

        // ---------- 13: byte recibido durante una transmision ----------
        n_rx      = 0;
        wdata_w   = W_TECLADO;
        wlen      = 4'd7;
        rev       = '0;
        errores_j = 3'd0;
        modo      = 1'b0;
        @(negedge clk);
        evento   = EV_INICIO;
        recibido = "";
        lanzar   = 1'b1;
        @(negedge clk);
        lanzar   = 1'b0;
        mandar_byte("M");                 // llega en plena trama
        while (busy_m) @(posedge clk);
        #(T_BIT * 12);
        repeat (40) @(negedge clk);
        comparar("START:F:07\nPATT:_______\nERR:6\n", "trama con una letra entrando a la vez");
        check(n_rx == 1, "la letra recibida durante la trama se perdio");
        check(ult_rx == "M", $sformatf("llego 0x%02h en vez de la M", ult_rx));

        // ---------- 8: al terminar no sigue transmitiendo ----------
        check(busy_m === 1'b0, "la capa quedo ocupada despues de terminar");
        n_antes = recibido.len();
        repeat (2000) @(negedge clk);
        check(recibido.len() == n_antes, "siguio transmitiendo sin que nadie se lo pidiera");

        $display("");
        if (errores == 0)
            $display("  PASS  protocolo, anchos, copia de datos, recepcion y filtrado de letras correctos");
        else
            $display("  FAIL  %0d comprobaciones fallidas", errores);
        $display("");
        $finish;
    end

endmodule
