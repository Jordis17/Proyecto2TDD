// =====================================================================
// tb_lcd_text_gen.sv - Testbench autoverificable
//
// lcd_text_gen es combinacional. Se fija un escenario de juego (palabra
// "GATO", 2 posiciones reveladas, 2 errores, modo dificil, 34 victorias)
// y se revisan puntos representativos de cada pantalla: el primer y el
// ultimo caracter de cada linea, el caracter donde cambia el contenido
// (revelado vs guion), y los comandos de posicionamiento de fila.
//
// Los valores esperados se calculan a mano contra las cadenas literales
// del RTL (no se copian del archivo, se transcriben del comentario/codigo
// para dejar constancia de la cuenta de columnas).
// =====================================================================
`timescale 1ns/1ps

module tb_lcd_text_gen;

    import lcd_screen_pkg::SCR_SELECT, lcd_screen_pkg::SCR_PLAY,
           lcd_screen_pkg::SCR_WIN, lcd_screen_pkg::SCR_LOSE_FALLOS,
           lcd_screen_pkg::SCR_LOSE_TIEMPO;

    localparam int MAX_LEN = 12;

    logic [2:0]           scr;
    logic                  fila;
    logic [3:0]            col;
    logic                  es_comando;
    logic [8*MAX_LEN-1:0]  word_data;
    logic [3:0]            word_len;
    logic [MAX_LEN-1:0]    revealed;
    logic [2:0]            errors_i;
    logic                  mode;
    logic [7:0]            wins;

    logic [7:0] byte_o;
    logic       rs_o;

    int errcnt = 0;
    int checks = 0;

    lcd_text_gen #(.MAX_LEN(MAX_LEN)) dut (
        .scr_i        (scr),
        .fila_i       (fila),
        .col_i        (col),
        .es_comando_i (es_comando),
        .word_data_i  (word_data),
        .word_len_i   (word_len),
        .revealed_i   (revealed),
        .errors_i     (errors_i),
        .mode_i       (mode),
        .wins_i       (wins),
        .byte_o       (byte_o),
        .rs_o         (rs_o)
    );

    task automatic check(string etiqueta, logic [7:0] exp_byte, logic exp_rs);
        checks++;
        if (byte_o !== exp_byte || rs_o !== exp_rs) begin
            errcnt++;
            $display("[FALLO] %s: esperado byte=0x%02h rs=%0b -- obtenido byte=0x%02h rs=%0b",
                      etiqueta, exp_byte, exp_rs, byte_o, rs_o);
        end
    endtask

    initial begin
        // ---- escenario fijo de partida ----
        word_data = {"GATO", 64'd0};   // 'G','A','T','O' en los bytes altos
        word_len  = 4'd4;
        revealed  = 12'b0000_0000_0101;  // posiciones 0 y 2 reveladas (G y T)
        errors_i  = 3'd2;                 // intentos restantes = 6-2 = 4
        mode      = 1'b1;                 // dificil
        wins      = 8'h34;                // '3','4'

        es_comando = 1'b0;

        // ---------------- comandos de posicion (no dependen de scr_i) ----------------
        es_comando = 1'b1;
        fila = 1'b0; col = 4'd0; scr = SCR_SELECT; #1;
        check("comando fila0", 8'h80, 1'b0);
        fila = 1'b1; col = 4'd7; scr = SCR_WIN; #1;
        check("comando fila1", 8'hC0, 1'b0);
        es_comando = 1'b0;

        // ---------------- SCR_SELECT ----------------
        scr = SCR_SELECT;
        fila = 1'b0; col = 4'd0;  #1; check("SELECT fila0 col0 ('A')",  8'h41, 1'b1);
        fila = 1'b0; col = 4'd11; #1; check("SELECT fila0 col11 (':')", 8'h3A, 1'b1);
        fila = 1'b0; col = 4'd12; #1; check("SELECT fila0 col12 (digito alto '3')", 8'h33, 1'b1);
        fila = 1'b0; col = 4'd13; #1; check("SELECT fila0 col13 (digito bajo '4')", 8'h34, 1'b1);
        fila = 1'b1; col = 4'd12; #1; check("SELECT fila1 dificil col12 ('L')", 8'h4C, 1'b1);
        mode = 1'b0;
        fila = 1'b1; col = 4'd10; #1; check("SELECT fila1 facil col10 ('L')", 8'h4C, 1'b1);
        fila = 1'b1; col = 4'd15; #1; check("SELECT fila1 facil col15 ('F')", 8'h46, 1'b1);
        mode = 1'b1;   // se restaura para el resto de las pruebas

        // ---------------- SCR_PLAY ----------------
        scr = SCR_PLAY;
        fila = 1'b0; col = 4'd0; #1; check("PLAY patron col0 revelado ('G')", 8'h47, 1'b1);
        fila = 1'b0; col = 4'd1; #1; check("PLAY patron col1 oculto ('_')",  8'h5F, 1'b1);
        fila = 1'b0; col = 4'd2; #1; check("PLAY patron col2 revelado ('T')", 8'h54, 1'b1);
        fila = 1'b0; col = 4'd3; #1; check("PLAY patron col3 oculto ('_')",  8'h5F, 1'b1);
        fila = 1'b0; col = 4'd4; #1; check("PLAY patron col4 fuera de palabra (' ')", 8'h20, 1'b1);
        fila = 1'b1; col = 4'd0;  #1; check("PLAY intentos col0 ('I')",           8'h49, 1'b1);
        fila = 1'b1; col = 4'd10; #1; check("PLAY intentos col10 (digito '4')",   8'h34, 1'b1);
        fila = 1'b1; col = 4'd15; #1; check("PLAY intentos col15 modo dificil ('D')", 8'h44, 1'b1);

        // ---------------- SCR_WIN ----------------
        scr = SCR_WIN;
        fila = 1'b0; col = 4'd3;  #1; check("WIN titulo col3 ('G')",  8'h47, 1'b1);
        fila = 1'b0; col = 4'd10; #1; check("WIN titulo col10 ('!')", 8'h21, 1'b1);
        fila = 1'b1; col = 4'd0;  #1; check("WIN palabra col0 ('G', revelado siempre)", 8'h47, 1'b1);
        fila = 1'b1; col = 4'd1;  #1; check("WIN palabra col1 ('A', revelado siempre)", 8'h41, 1'b1);
        fila = 1'b1; col = 4'd4;  #1; check("WIN palabra col4 fuera de palabra (' ')",  8'h20, 1'b1);

        // ---------------- SCR_LOSE_FALLOS ----------------
        scr = SCR_LOSE_FALLOS;
        fila = 1'b0; col = 4'd0;  #1; check("LOSE_FALLOS titulo col0 ('P')",  8'h50, 1'b1);
        fila = 1'b0; col = 4'd15; #1; check("LOSE_FALLOS titulo col15 ('S')", 8'h53, 1'b1);
        fila = 1'b1; col = 4'd3;  #1; check("LOSE_FALLOS palabra col3 ('O', revelado siempre)", 8'h4F, 1'b1);

        // ---------------- SCR_LOSE_TIEMPO ----------------
        scr = SCR_LOSE_TIEMPO;
        fila = 1'b0; col = 4'd0;  #1; check("LOSE_TIEMPO titulo col0 ('P')",  8'h50, 1'b1);
        fila = 1'b0; col = 4'd15; #1; check("LOSE_TIEMPO titulo col15 ('O')", 8'h4F, 1'b1);
        fila = 1'b1; col = 4'd2;  #1; check("LOSE_TIEMPO palabra col2 ('T', revelado siempre)", 8'h54, 1'b1);

        $display("----------------------------------------------------");
        if (errcnt == 0)
            $display("PASA: lcd_text_gen (%0d verificaciones)", checks);
        else
            $display("FALLA: lcd_text_gen (%0d de %0d verificaciones fallaron)",
                      errcnt, checks);
        $display("----------------------------------------------------");
        $finish;
    end

endmodule
