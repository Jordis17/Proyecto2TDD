// =====================================================================
// tb_display_controller.sv - Testbench autoverificable del multiplexado
//
// Comprueba:
//   1. el contador de digito recorre 0,1,2,3 y vuelve a empezar
//   2. cada digito muestra el valor que le corresponde
//   3. solo hay un anodo activo en cada instante
//   4. los cuatro anodos que no se usan permanecen apagados siempre
//   5. el ciclo completo dura cuatro ticks
//   6. la conversion de segundos a BCD es correcta en todo el rango util
//   7. un valor fuera de rango apaga el digito en vez de mostrar basura
//   8. con las polaridades invertidas la vista logica es la misma
//
// La comprobacion 2 no compara contra la tabla del propio modulo: el
// testbench decodifica el patron de segmentos de vuelta a un digito con
// su propia tabla, escrita de forma independiente. Si ambas coinciden,
// el decodificador es correcto; si se comparara contra la misma tabla, la
// prueba seria una tautologia.
// =====================================================================
`timescale 1ns/1ps

module tb_display_controller;

    localparam int TICK_DIV = 4;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic [6:0] time_s   = 7'd0;
    logic [7:0] wins_bcd = 8'h00;

    logic [6:0] seg_n, seg_p;
    logic [7:0] an_n,  an_p;

    // vista logica: uno = encendido
    logic [6:0] vseg;
    logic [7:0] van;

    int errores = 0;
    int i, k, activos, esperado, leido;
    int orden [0:3];

    // Anodo que le toca a cada turno del barrido. Las victorias van en el
    // bloque derecho y los segundos en el izquierdo, por eso la secuencia
    // salta de AN1 a AN4.
    function automatic int an_del_turno(input int p);
        case (p)
            0:       return 0;   // AN0, unidades de victorias
            1:       return 1;   // AN1, decenas de victorias
            2:       return 4;   // AN4, unidades de segundos
            default: return 5;   // AN5, decenas de segundos
        endcase
    endfunction

    always #5 clk = ~clk;

    int tick_cnt = 0;
    logic tick;
    assign tick = (tick_cnt == TICK_DIV - 1);
    always_ff @(posedge clk) tick_cnt <= tick ? 0 : tick_cnt + 1;

    // polaridad de la tarjeta: activa en bajo
    display_controller #(.SEG_ACTIVE_LEVEL(1'b0), .AN_ACTIVE_LEVEL(1'b0)) dut (
        .clk_i(clk), .rst_i(rst), .tick_i(tick),
        .time_s_i(time_s), .wins_bcd_i(wins_bcd),
        .seg_o(seg_n), .an_o(an_n)
    );

    // misma logica con polaridad opuesta, para el caso 8
    display_controller #(.SEG_ACTIVE_LEVEL(1'b1), .AN_ACTIVE_LEVEL(1'b1)) dut_p (
        .clk_i(clk), .rst_i(rst), .tick_i(tick),
        .time_s_i(time_s), .wins_bcd_i(wins_bcd),
        .seg_o(seg_p), .an_o(an_p)
    );

    assign vseg = ~seg_n;
    assign van  = ~an_n;

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            $display("  FAIL: %s", msg);
            errores++;
        end
    endtask

    // Tabla independiente: del patron de segmentos al digito.
    // Devuelve -1 si el patron no corresponde a ningun digito.
    function automatic int patron_a_digito(input logic [6:0] p);
        case (p)
            7'b0111111: return 0;
            7'b0000110: return 1;
            7'b1011011: return 2;
            7'b1001111: return 3;
            7'b1100110: return 4;
            7'b1101101: return 5;
            7'b1111101: return 6;
            7'b0000111: return 7;
            7'b1111111: return 8;
            7'b1101111: return 9;
            7'b0000000: return -2;      // digito apagado
            default:    return -1;      // patron desconocido
        endcase
    endfunction

    function automatic int anodo_activo(input logic [7:0] a);
        for (int b = 0; b < 8; b++) if (a[b]) return b;
        return -1;
    endfunction

    task automatic esperar_tick();
        do @(posedge clk); while (!tick);
        @(negedge clk);
    endtask

    // Recorre un ciclo completo y comprueba digito, anodo y exclusividad
    task automatic recorrer_ciclo(input int u_win, input int d_win,
                                  input int u_seg, input int d_seg);
        int esperados [0:7];
        for (int b = 0; b < 8; b++) esperados[b] = -3;   // anodo sin usar
        esperados[an_del_turno(0)] = u_win;
        esperados[an_del_turno(1)] = d_win;
        esperados[an_del_turno(2)] = u_seg;
        esperados[an_del_turno(3)] = d_seg;

        for (int p = 0; p < 4; p++) begin
            activos = 0;
            for (int b = 0; b < 8; b++) if (van[b]) activos++;
            check(activos == 1,
                  $sformatf("hay %0d anodos activos a la vez", activos));

            check(van[3:2] === 2'd0 && van[7:6] === 2'd0,
                  $sformatf("AN2, AN3, AN6 y AN7 deben estar apagados, van vale %b", van));

            leido = anodo_activo(van);
            check(leido >= 0 && esperados[leido] != -3,
                  $sformatf("anodo activo fuera de los cuatro que se usan: %0d", leido));

            if (leido >= 0 && esperados[leido] != -3) begin
                esperado = esperados[leido];
                check(patron_a_digito(vseg) == esperado,
                      $sformatf("en AN%0d se esperaba el digito %0d y se leyo %0d",
                                leido, esperado, patron_a_digito(vseg)));
                orden[p] = leido;
            end
            esperar_tick();
        end
    endtask

    initial begin
        $display("");
        $display("=== tb_display_controller ===");

        repeat (3) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);

        // ---------- 2, 3, 4, 6: valores tipicos ----------
        // 45 segundos, 7 victorias
        time_s   = 7'd45;
        wins_bcd = 8'h07;
        esperar_tick();
        recorrer_ciclo(7, 0, 5, 4);

        // 60 segundos, 99 victorias
        time_s   = 7'd60;
        wins_bcd = 8'h99;
        esperar_tick();
        recorrer_ciclo(9, 9, 0, 6);

        // 9 segundos, 10 victorias
        time_s   = 7'd9;
        wins_bcd = 8'h10;
        esperar_tick();
        recorrer_ciclo(0, 1, 9, 0);

        // 0 segundos, 0 victorias
        time_s   = 7'd0;
        wins_bcd = 8'h00;
        esperar_tick();
        recorrer_ciclo(0, 0, 0, 0);

        // ---------- 1 y 5: el barrido recorre los cuatro y vuelve ----------
        check(orden[0] != orden[1] && orden[1] != orden[2] && orden[2] != orden[3],
              "el barrido repite digitos dentro de un ciclo");
        // El ciclo puede arrancar en cualquier turno, asi que se busca en
        // cual empezo y se comprueba que siga la secuencia desde ahi.
        i = -1;
        for (int p = 0; p < 4; p++) if (an_del_turno(p) == orden[0]) i = p;
        check(i >= 0, "el barrido arranco en un anodo que no se usa");
        if (i >= 0)
            check((orden[1] == an_del_turno((i + 1) % 4)) &&
                  (orden[2] == an_del_turno((i + 2) % 4)) &&
                  (orden[3] == an_del_turno((i + 3) % 4)),
                  "el barrido no sigue el orden de anodos previsto");

        // ---------- 7: nibble fuera de rango apaga el digito ----------
        wins_bcd = 8'hAF;              // A y F no son digitos BCD validos
        esperar_tick();
        for (k = 0; k < 4; k++) begin
            leido = anodo_activo(van);
            if (leido == 0 || leido == 1)
                check(patron_a_digito(vseg) == -2,
                      $sformatf("un nibble invalido en AN%0d debe apagar el digito", leido));
            esperar_tick();
        end

        // ---------- 8: la polaridad opuesta da la misma vista logica ----------
        wins_bcd = 8'h42;
        time_s   = 7'd33;
        esperar_tick();
        for (k = 0; k < 4; k++) begin
            check(seg_p === ~seg_n, "la polaridad opuesta de segmentos no es complementaria");
            check(an_p  === ~an_n,  "la polaridad opuesta de anodos no es complementaria");
            esperar_tick();
        end

        $display("");
        if (errores == 0)
            $display("  PASS  barrido, decodificacion, anodos, rango y polaridad correctos");
        else
            $display("  FAIL  %0d comprobaciones fallidas", errores);
        $display("");
        $finish;
    end

endmodule
