// =====================================================================
// tb_word_rom.sv - Testbench autoverificable del banco de palabras
//
// Comprueba las propiedades de las que depende la seleccion de palabra:
//   1. toda longitud esta entre 4 y 12
//   2. los indices 0..31 tienen longitud >= 6   (modo dificil)
//   3. los indices 32..63 tienen longitud 4 o 5 (solo modo facil)
//   4. las posiciones validas contienen solo A-Z (sin minusculas ni acentos ni caracteres especiales)
//   5. las posiciones de relleno contienen espacio
//
//
// =====================================================================
`timescale 1ns/1ps

module tb_word_rom;

    localparam int MAX_LEN   = 12;
    localparam int N_WORDS   = 64;
    localparam int N_HARD    = 32;
    localparam int HARD_MIN  = 6;

    logic [5:0]             idx;
    logic [8*MAX_LEN-1:0]   data;
    logic [3:0]             len;

    int  errores = 0;
    int  i, j;
    logic [7:0] ch;

    word_rom dut (
        .index_i     (idx),
        .word_data_o (data),
        .word_len_o  (len)
    );

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $display("  FAIL indice %0d: %s", idx, msg);
            errores++;
        end
    endtask

    initial begin
        $display("");
        $display("=== tb_word_rom ===");

        for (i = 0; i < N_WORDS; i++) begin
            idx = i[5:0];
            #1;

            check(len >= 4 && len <= MAX_LEN, "longitud fuera del rango 4..12");

            if (i < N_HARD)
                check(len >= HARD_MIN, "los indices 0..31 deben tener longitud >= 6");
            else
                check(len == 4 || len == 5, "los indices 32..63 deben tener 4 o 5");

            for (j = 0; j < MAX_LEN; j++) begin
                ch = data[8*(MAX_LEN-1-j) +: 8];
                if (j < len)
                    check(ch >= "A" && ch <= "Z",
                          $sformatf("la posicion %0d no es una no es caracter valido", j));
                else
                    check(ch == " ",
                          $sformatf("la posicion %0d de relleno no es espacio", j));
            end
        end

        $display("");
        if (errores == 0)
            $display("  PASS  %0d palabras: longitudes, orden por dificultad y relleno correctos", N_WORDS);
        else
            $display("  FAIL  %0d comprobaciones fallidas", errores);
        $display("");
        $finish;
    end

endmodule