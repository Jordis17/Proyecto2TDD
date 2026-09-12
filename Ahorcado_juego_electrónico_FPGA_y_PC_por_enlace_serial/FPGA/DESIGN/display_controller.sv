// =====================================================================
// display_controller.sv - Multiplexado de los displays de 7 segmentos
//
// Los cuatro digitos que usa el juego comparten fisicamente las siete
// lineas de segmento, por lo que no se pueden encender todos a la vez.
// Para mostrarlos se van activando uno por uno, lo suficientemente
// rapido como para que el ojo los perciba como si estuvieran encendidos
// al mismo tiempo.
//
// El cambio de digito se hace con cada tick de 1 ms. Como hay cuatro
// digitos, una vuelta completa toma 4 ms, dando un refresco de 250 Hz.
// Esto es suficiente para que el cambio entre digitos no sea visible.
//
// Las dos cantidades van en bloques distintos de la tarjeta para que no
// se lean como un solo numero: AN0 y AN1 muestran las victorias y AN4 y
// AN5 los segundos restantes, uno a cada lado del hueco que separa los
// dos grupos de displays. AN2, AN3, AN6 y AN7 no se utilizan.
//
// Para hacer mas facil de leer las tablas, dentro del modulo se trabaja
// con 1 = encendido. La polaridad real de la tarjeta se aplica al final.
// =====================================================================

module display_controller #(
    parameter logic SEG_ACTIVE_LEVEL = 1'b0,   // 0 = segmento enciende con nivel bajo
    parameter logic AN_ACTIVE_LEVEL  = 1'b0    // 0 = digito habilita con nivel bajo
) (
    input  logic       clk_i,
    input  logic       rst_i,
    input  logic       tick_i,       // pulso de 1 ms
    input  logic [6:0] time_s_i,     // segundos restantes, 0..60
    input  logic [7:0] wins_bcd_i,   // victorias en BCD, dos digitos
    output logic [6:0] seg_o,        // {g,f,e,d,c,b,a}
    output logic [7:0] an_o          // habilitacion de cada digito
);

    logic [1:0] dig_q = 2'd0;
    logic [3:0] t_dec, t_uni, nibble;
    logic [6:0] seg;
    logic [7:0] an;

    // Este contador indica cual de los cuatro digitos se esta
    // mostrando. Como solo tiene dos bits, despues del digito 3 vuelve
    // automaticamente al 0.
    always_ff @(posedge clk_i) begin
        if (rst_i)       dig_q <= 2'd0;
        else if (tick_i) dig_q <= dig_q + 2'd1;
    end

    // El tiempo llega como un numero binario, pero para mostrarlo en
    // los displays necesitamos separar las decenas de las unidades.
    logic [6:0] cociente;
    logic [3:0] residuo;

    assign cociente = time_s_i / 7'd10;

    // El residuo de dividir entre 10 siempre esta entre 0 y 9, por lo
    // que cuatro bits son suficientes para guardarlo.
    assign residuo = time_s_i % 7'd10;

    // Normalmente el tiempo esta entre 0 y 60. Si por alguna razon
    // llega un valor que necesita mas de dos digitos, se manda un valor
    // invalido para que el decodificador apague ese digito.
    assign t_dec = (cociente > 7'd9) ? 4'hF : cociente[3:0];
    assign t_uni = residuo;

    // Las victorias ya vienen en BCD, asi que solo se separan las
    // unidades y las decenas para poder mostrarlas por separado.
    logic [3:0] win_uni, win_dec;
    assign win_uni = wins_bcd_i[3:0];
    assign win_dec = wins_bcd_i[7:4];

    // Dependiendo del turno se escoge el numero que se va a mostrar.
    // Asi, aunque todos los digitos comparten las mismas lineas de
    // segmentos, cada uno puede mostrar un valor diferente.
    always_comb begin
        unique case (dig_q)
            2'd0:    nibble = win_uni;
            2'd1:    nibble = win_dec;
            2'd2:    nibble = t_uni;
            2'd3:    nibble = t_dec;
            default: nibble = 4'd0;
        endcase
    end

    // Esta tabla convierte el numero en los segmentos que deben
    // encenderse. Los bits estan en el orden {g,f,e,d,c,b,a}.
    always_comb begin
        unique case (nibble)
            4'd0:    seg = 7'b0111111;
            4'd1:    seg = 7'b0000110;
            4'd2:    seg = 7'b1011011;
            4'd3:    seg = 7'b1001111;
            4'd4:    seg = 7'b1100110;
            4'd5:    seg = 7'b1101101;
            4'd6:    seg = 7'b1111101;
            4'd7:    seg = 7'b0000111;
            4'd8:    seg = 7'b1111111;
            4'd9:    seg = 7'b1101111;
            // Si llega algo que no corresponde a un digito decimal,
            // se apagan todos los segmentos.
            default: seg = 7'b0000000;
        endcase
    end

    // Aqui se indica cual de los digitos esta activo. Las victorias van
    // en AN0 y AN1 y los segundos en AN4 y AN5, asi que cada cantidad
    // queda en un bloque distinto. Los otros cuatro quedan apagados.
    always_comb begin
        unique case (dig_q)
            2'd0:    an = 8'b0000_0001;   // AN0, unidades de victorias
            2'd1:    an = 8'b0000_0010;   // AN1, decenas de victorias
            2'd2:    an = 8'b0001_0000;   // AN4, unidades de segundos
            2'd3:    an = 8'b0010_0000;   // AN5, decenas de segundos
            default: an = 8'b0000_0000;
        endcase
    end

    // Internamente usamos 1 = encendido. Aqui se cambia la señal a la
    // polaridad que necesita la tarjeta, tanto para los segmentos como
    // para los anodos.
    assign seg_o = SEG_ACTIVE_LEVEL ? seg : ~seg;
    assign an_o  = AN_ACTIVE_LEVEL  ? an  : ~an;

endmodule
