// =====================================================================
// tb_lcd_screen_snapshot.sv - Testbench autoverificable
//
// Verifica:
//   1. Sin capture_i, las salidas mantienen el valor inicial (o el ultimo
//      capturado) aunque las entradas cambien.
//   2. Con capture_i en alto un ciclo, todas las salidas se actualizan
//      juntas al valor de las entradas en ese ciclo.
//   3. Un segundo capture_i con datos distintos vuelve a actualizar todo
//      (no queda "pegado" al primer valor).
// =====================================================================
`timescale 1ns/1ps

module tb_lcd_screen_snapshot;

    localparam int MAX_LEN = 12;
    localparam int CLK_PERIOD = 10;

    logic clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    logic                   capture;
    logic [2:0]             screen;
    logic [8*MAX_LEN-1:0]   word_data;
    logic [3:0]             word_len;
    logic [MAX_LEN-1:0]     revealed;
    logic [2:0]             errors_i;
    logic                   mode;
    logic [7:0]             wins;

    logic [2:0]             scr_o;
    logic [8*MAX_LEN-1:0]   word_data_o;
    logic [3:0]             word_len_o;
    logic [MAX_LEN-1:0]     revealed_o;
    logic [2:0]             errors_o;
    logic                   mode_o;
    logic [7:0]             wins_o;

    int errcnt = 0;
    int checks = 0;

    lcd_screen_snapshot #(.MAX_LEN(MAX_LEN)) dut (
        .clk_i       (clk),
        .capture_i   (capture),
        .screen_i    (screen),
        .word_data_i (word_data),
        .word_len_i  (word_len),
        .revealed_i  (revealed),
        .errors_i    (errors_i),
        .mode_i      (mode),
        .wins_i      (wins),
        .scr_o       (scr_o),
        .word_data_o (word_data_o),
        .word_len_o  (word_len_o),
        .revealed_o  (revealed_o),
        .errors_o    (errors_o),
        .mode_o      (mode_o),
        .wins_o      (wins_o)
    );

    task automatic check_snapshot(string etapa,
                                   logic [2:0] e_scr, logic [8*MAX_LEN-1:0] e_wd,
                                   logic [3:0] e_wl, logic [MAX_LEN-1:0] e_rev,
                                   logic [2:0] e_err, logic e_mode, logic [7:0] e_wins);
        checks++;
        if (scr_o !== e_scr || word_data_o !== e_wd || word_len_o !== e_wl ||
            revealed_o !== e_rev || errors_o !== e_err || mode_o !== e_mode ||
            wins_o !== e_wins) begin
            errcnt++;
            $display("[FALLO] %s: snapshot no coincide con lo esperado", etapa);
            $display("        scr=%0d(esp %0d) wl=%0d(esp %0d) err=%0d(esp %0d) mode=%0b(esp %0b) wins=%0d(esp %0d)",
                      scr_o, e_scr, word_len_o, e_wl, errors_o, e_err, mode_o, e_mode, wins_o, e_wins);
            if (word_data_o !== e_wd) $display("        word_data no coincide");
            if (revealed_o  !== e_rev) $display("        revealed no coincide");
        end
    endtask

    initial begin
        capture   = 1'b0;
        screen    = 3'd0;
        word_data = '0;
        word_len  = 4'd0;
        revealed  = '0;
        errors_i  = 3'd0;
        mode      = 1'b0;
        wins      = 8'h00;

        @(posedge clk);
        // Estado inicial (valores declarados en el DUT): debe verse como 0.
        check_snapshot("reposo inicial", 3'd0, '0, 4'd0, '0, 3'd0, 1'b0, 8'h00);

        // Cambiar entradas SIN capture_i: la salida no debe moverse.
        screen    = 3'd2;
        word_len  = 4'd5;
        wins      = 8'h34;
        @(posedge clk);
        check_snapshot("cambio de entrada sin capture_i", 3'd0, '0, 4'd0, '0, 3'd0, 1'b0, 8'h00);

        // Pulso de capture_i: debe tomar el valor presente ese ciclo.
        screen    = 3'd1;
        word_data = {"GATO", 64'd0};
        word_len  = 4'd4;
        revealed  = 12'b0000_0000_0011;
        errors_i  = 3'd2;
        mode      = 1'b1;
        wins      = 8'h12;
        capture   = 1'b1;
        @(posedge clk);
        capture   = 1'b0;
        #1;
        check_snapshot("tras primer capture_i", 3'd1, {"GATO", 64'd0}, 4'd4,
                       12'b0000_0000_0011, 3'd2, 1'b1, 8'h12);

        // Cambiar entradas de nuevo sin capture_i: debe seguir igual.
        screen   = 3'd3;
        mode     = 1'b0;
        @(posedge clk);
        check_snapshot("cambio posterior sin capture_i", 3'd1, {"GATO", 64'd0}, 4'd4,
                       12'b0000_0000_0011, 3'd2, 1'b1, 8'h12);

        // Segundo pulso de capture_i con datos distintos: debe actualizar todo.
        screen    = 3'd4;
        word_data = {"PERROS", 48'd0};
        word_len  = 4'd6;
        revealed  = 12'b1111_1111_1111;
        errors_i  = 3'd6;
        mode      = 1'b0;
        wins      = 8'h99;
        capture   = 1'b1;
        @(posedge clk);
        capture   = 1'b0;
        #1;
        check_snapshot("tras segundo capture_i", 3'd4, {"PERROS", 48'd0}, 4'd6,
                       12'b1111_1111_1111, 3'd6, 1'b0, 8'h99);

        $display("----------------------------------------------------");
        if (errcnt == 0)
            $display("PASA: lcd_screen_snapshot (%0d verificaciones)", checks);
        else
            $display("FALLA: lcd_screen_snapshot (%0d de %0d verificaciones fallaron)",
                      errcnt, checks);
        $display("----------------------------------------------------");
        $finish;
    end

endmodule
