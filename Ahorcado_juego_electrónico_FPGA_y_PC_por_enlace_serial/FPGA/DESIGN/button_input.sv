// =====================================================================
// button_input.sv - Acondicionamiento de un pulsador
//
// El boton pasa por tres etapas antes de usarse en el resto del
// sistema: primero se sincroniza con el reloj, luego se espera a que
// la señal se mantenga estable para evitar los rebotes y finalmente
// se genera un pulso cuando se detecta una nueva pulsacion.
//
// Internamente se trabaja con 1 = boton presionado, sin importar si
// el boton fisico trabaja con logica activa en alto o en bajo.
//
// Se instancia tres veces, una por cada boton del juego. El reinicio
// usa el nivel filtrado y los otros dos usan el pulso, por eso el
// modulo entrega las dos formas.
// =====================================================================

module button_input #(
    parameter int   DEBOUNCE_MS      = 10,
    parameter logic BTN_ACTIVE_LEVEL = 1'b1
) (
    input  logic clk_i,
    input  logic rst_i,
    input  logic tick_i,     // pulso de 1 ms
    input  logic btn_i,      // entrada fisica, asincrona
    output logic pulse_o,    // un ciclo por pulsacion
    output logic level_o     // nivel ya filtrado (1 = presionado)
);

    // Bits necesarios para contar hasta DEBOUNCE_MS. El caso de 1 o
    // menos se aparta porque $clog2(1) da cero, y un vector de cero
    // bits no es valido.
    localparam int W = (DEBOUNCE_MS <= 1) ? 1 : $clog2(DEBOUNCE_MS);

    logic         btn_norm;
    logic         sync_q1  = 1'b0;
    logic         sync_q2  = 1'b0;
    logic         stable_q = 1'b0;
    logic         stable_d = 1'b0;
    logic [W-1:0] cnt_q    = '0;

    // Desde este punto ya no importa si el boton original era activo
    // en alto o en bajo: un 1 siempre representa que esta presionado.
    assign btn_norm = (btn_i == BTN_ACTIVE_LEVEL);

    assign level_o = stable_q;
    assign pulse_o = stable_q & ~stable_d;

    // El boton cambia en cualquier momento respecto al reloj, asi que
    // el primer flip-flop puede quedar metaestable si el cambio le cae
    // justo encima del flanco. El segundo le da un ciclo completo para
    // que se resuelva, y es su salida la que usa el resto del modulo.
    always_ff @(posedge clk_i) begin
        sync_q1 <= btn_norm;
        sync_q2 <= sync_q1;
    end

    // Despues de sincronizar, se comprueba que el cambio se mantenga
    // durante el tiempo definido. Esto evita tomar como una pulsacion
    // los cambios rapidos que produce el rebote del boton.
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            cnt_q    <= '0;
            stable_q <= 1'b0;
        end else if (sync_q2 == stable_q) begin
            // Si la señal regreso al estado que ya considerabamos
            // estable, no hay nada que contar.
            cnt_q <= '0;
        end else if (tick_i) begin
            // Se cuenta una vez por cada tick de 1 ms. Como la pulsacion
            // puede caer en cualquier punto entre dos ticks, el filtro
            // termina durando entre 9 y 10 ms y no 10 exactos.
            if (cnt_q == W'(DEBOUNCE_MS - 1)) begin
                // El cambio se mantuvo el tiempo suficiente, asi que
                // ahora si lo aceptamos como un nuevo estado del boton.
                stable_q <= sync_q2;
                cnt_q    <= '0;
            end else begin
                cnt_q <= cnt_q + 1'b1;
            end
        end
    end

    // Se guarda el estado estable del ciclo anterior. Al comparar
    // stable_q con stable_d se obtiene un solo ciclo de pulso cuando
    // el boton pasa de soltado a presionado.
    always_ff @(posedge clk_i) begin
        if (rst_i) stable_d <= 1'b0;
        else       stable_d <= stable_q;
    end

endmodule