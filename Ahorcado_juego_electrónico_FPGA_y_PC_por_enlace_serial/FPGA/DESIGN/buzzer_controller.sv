// =====================================================================
// buzzer_controller.sv - Retroalimentacion sonora
//
// Genera una onda cuadrada distinta segun el evento del juego:
//
//   Acierto     2 kHz                       100 ms
//   Error       500 Hz                      150 ms
//   Victoria    2 kHz -> 2,5 kHz -> 3 kHz   150 ms cada tono
//   Derrota     800 Hz -> 500 Hz            200 ms cada tono
//
// El acierto es agudo y corto y el error grave y un poco mas largo,
// para que se distingan sin mirar la pantalla. La victoria sube de tono
// y la derrota baja, que es lo que uno espera oir en cada caso.
//
// La Nexys 4 no trae zumbador, asi que la onda sale por el amplificador
// PWM de la tarjeta y hay que conectar audifonos o un parlante.
// =====================================================================

module buzzer_controller #(
    parameter int   CLK_HZ           = 100_000_000,
    parameter logic AMP_ENABLE_LEVEL = 1'b1
) (
    input  logic       clk_i,
    input  logic       rst_i,
    input  logic       tick_i,        // pulso de 1 ms
    input  logic [2:0] snd_event_i,   // evento a reproducir
    input  logic       snd_start_i,   // pulso de disparo
    output logic       aud_pwm_o,
    output logic       aud_sd_o,
    output logic       busy_o         // hay un sonido en curso
);

    // Codigos que envia el control del juego.
    localparam logic [2:0] EV_NINGUNO  = 3'd0;
    localparam logic [2:0] EV_ACIERTO  = 3'd1;
    localparam logic [2:0] EV_ERROR    = 3'd2;
    localparam logic [2:0] EV_VICTORIA = 3'd3;
    localparam logic [2:0] EV_DERROTA  = 3'd4;

    // Una onda cuadrada cambia de estado cada medio periodo. Estos
    // valores indican cuantos ciclos de reloj dura cada semiperiodo.
    // Se suma la frecuencia antes de dividir para redondear el resultado.
    localparam int SP_2K0 = (CLK_HZ + 2000) / (2 * 2000);
    localparam int SP_2K5 = (CLK_HZ + 2500) / (2 * 2500);
    localparam int SP_3K0 = (CLK_HZ + 3000) / (2 * 3000);
    localparam int SP_800 = (CLK_HZ +  800) / (2 *  800);
    localparam int SP_500 = (CLK_HZ +  500) / (2 *  500);

    // El tono de 500 Hz tiene el semiperiodo mas largo, asi que se usa
    // para determinar el ancho del contador.
    localparam int W_DIV = (SP_500 <= 1) ? 1 : $clog2(SP_500 + 1);

    logic              sonando_q = 1'b0;
    logic [2:0]        ev_q      = EV_NINGUNO;
    logic [1:0]        tono_q    = 2'd0;
    logic [W_DIV-1:0]  div_q     = '0;
    logic [7:0]        ms_q      = '0;
    logic              pwm_q     = 1'b0;

    // Segun el evento y el tono actual se escogen el semiperiodo y la
    // duracion correspondientes.
    logic [W_DIV-1:0] semiperiodo;
    logic [7:0]       duracion;
    logic             es_ultimo;

    always_comb begin
        unique case (ev_q)
            EV_ACIERTO: begin
                semiperiodo = W_DIV'(SP_2K0);
                duracion    = 8'd100;
                es_ultimo   = 1'b1;
            end

            EV_ERROR: begin
                semiperiodo = W_DIV'(SP_500);
                duracion    = 8'd150;
                es_ultimo   = 1'b1;
            end

            EV_VICTORIA: begin
                duracion = 8'd150;
                unique case (tono_q)
                    2'd0:    begin semiperiodo = W_DIV'(SP_2K0); es_ultimo = 1'b0; end
                    2'd1:    begin semiperiodo = W_DIV'(SP_2K5); es_ultimo = 1'b0; end
                    default: begin semiperiodo = W_DIV'(SP_3K0); es_ultimo = 1'b1; end
                endcase
            end

            EV_DERROTA: begin
                duracion = 8'd200;
                unique case (tono_q)
                    2'd0:    begin semiperiodo = W_DIV'(SP_800); es_ultimo = 1'b0; end
                    default: begin semiperiodo = W_DIV'(SP_500); es_ultimo = 1'b1; end
                endcase
            end

            default: begin
                semiperiodo = W_DIV'(SP_2K0);
                duracion    = 8'd1;
                es_ultimo   = 1'b1;
            end
        endcase
    end

    // Un sonido nuevo se acepta solo si no hay otro sonando. La excepcion
    // son los eventos de fin de partida, que pueden interrumpir el sonido
    // actual para reproducir la victoria o la derrota.
    logic es_fin, acepta;

    assign es_fin = (snd_event_i == EV_VICTORIA) || (snd_event_i == EV_DERROTA);
    assign acepta = snd_start_i && (snd_event_i != EV_NINGUNO) && (!sonando_q || es_fin);

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            sonando_q <= 1'b0;
            ev_q      <= EV_NINGUNO;
            tono_q    <= 2'd0;
            div_q     <= '0;
            ms_q      <= '0;
            pwm_q     <= 1'b0;
        end else if (acepta) begin
            sonando_q <= 1'b1;
            ev_q      <= snd_event_i;
            tono_q    <= 2'd0;
            div_q     <= '0;
            ms_q      <= '0;
            pwm_q     <= 1'b0;
        end else if (sonando_q) begin

            // Cada vez que el contador llega al semiperiodo se invierte
            // la salida y se reinicia el contador. Asi se genera la onda.
            if (div_q == semiperiodo - 1) begin
                div_q <= '0;
                pwm_q <= ~pwm_q;
            end else begin
                div_q <= div_q + 1'b1;
            end

            // La duracion se mide en milisegundos con el tick. Al llegar
            // al final se pasa al siguiente tono, o se detiene el sonido
            // si era el ultimo.
            if (tick_i) begin
                if (ms_q == duracion - 8'd1) begin
                    ms_q <= '0;

                    if (es_ultimo) begin
                        sonando_q <= 1'b0;
                        pwm_q     <= 1'b0;
                    end else begin
                        tono_q <= tono_q + 2'd1;
                        div_q  <= '0;
                        pwm_q  <= 1'b0;
                    end
                end else begin
                    ms_q <= ms_q + 8'd1;
                end
            end
        end
    end

    assign aud_pwm_o = pwm_q;
    assign aud_sd_o  = AMP_ENABLE_LEVEL;
    assign busy_o    = sonando_q;

endmodule

