// =====================================================================
// tb_lcd_step_decoder.sv - Testbench autoverificable
//
// lcd_step_decoder es puramente combinacional: se recorren los 34 pasos
// validos (0..33) y se compara cada salida contra un modelo de
// referencia calculado de forma independiente en este mismo testbench
// (no se copia la formula del RTL, se recalcula con la definicion del
// enunciado: "paso 0 = comando fila 0, pasos 1..16 = caracteres fila 0,
// paso 17 = comando fila 1, pasos 18..33 = caracteres fila 1").
//
// Reporta cada fallo por consola y termina con un resumen PASA/FALLA.
// =====================================================================
`timescale 1ns/1ps

module tb_lcd_step_decoder;

    logic [5:0] paso;
    logic       es_comando, fila, es_ultimo;
    logic [3:0] col;

    int errors = 0;
    int checks = 0;

    lcd_step_decoder dut (
        .paso_i       (paso),
        .es_comando_o (es_comando),
        .fila_o       (fila),
        .col_o        (col),
        .es_ultimo_o  (es_ultimo)
    );

    task automatic check_bit(string nombre, logic got, logic exp);
        checks++;
        if (got !== exp) begin
            errors++;
            $display("[FALLO] paso=%0d %s: esperado=%0b obtenido=%0b",
                      paso, nombre, exp, got);
        end
    endtask

    task automatic check_col(logic [3:0] got, logic [3:0] exp);
        checks++;
        if (got !== exp) begin
            errors++;
            $display("[FALLO] paso=%0d col: esperado=%0d obtenido=%0d",
                      paso, exp, got);
        end
    endtask

    initial begin
        logic exp_comando, exp_fila, exp_ultimo;
        logic [3:0] exp_col;

        for (int p = 0; p <= 33; p++) begin
            paso = p[5:0];
            #1;

            // ---- modelo de referencia, independiente del RTL ----
            exp_comando = (p == 0) || (p == 17);
            exp_fila    = (p >= 17);
            exp_ultimo  = (p == 33);

            check_bit("es_comando", es_comando, exp_comando);
            check_bit("fila",       fila,       exp_fila);
            check_bit("es_ultimo",  es_ultimo,  exp_ultimo);

            // col solo tiene significado definido en los pasos de
            // caracter (no comando); ahi si se verifica con precision.
            if (!exp_comando) begin
                if (p <= 16) exp_col = 4'(p - 1);   // fila 0: 1..16 -> 0..15
                else         exp_col = 4'(p - 18);  // fila 1: 18..33 -> 0..15
                check_col(col, exp_col);
            end
        end

        // Casos puntuales de wraparound mencionados en la documentacion
        paso = 6'd16; #1;
        check_col(col, 4'd15);   // ultimo caracter fila 0
        paso = 6'd33; #1;
        check_col(col, 4'd15);   // ultimo caracter fila 1

        $display("----------------------------------------------------");
        if (errors == 0)
            $display("PASA: lcd_step_decoder (%0d verificaciones)", checks);
        else
            $display("FALLA: lcd_step_decoder (%0d de %0d verificaciones fallaron)",
                      errors, checks);
        $display("----------------------------------------------------");
        $finish;
    end

endmodule
