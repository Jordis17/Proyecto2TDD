// =====================================================================
// uart_msg_char_gen.sv - Que caracter va en cada posicion del mensaje
//
// Todo el formato del protocolo vive aqui. Recibe los datos congelados
// de la jugada, mas el numero de linea y la posicion dentro de la linea,
// y entrega el caracter que corresponde. Es combinacional: no guarda
// nada y no sabe nada del periferico.
//
// Mensajes
// --------
//   evento        lineas que emite
//   inicio        START:<M>:<LL>   PATT:<p>   ERR:<n>
//   letra         LET:<X>:<R>      PATT:<p>   ERR:<n>
//   repetida      LET:<X>:RPT
//   fin           END:<E>:<W>
//
//   <M>  F o D            <LL> longitud con dos digitos
//   <p>  patron, con guion bajo en lo oculto, tantos caracteres como
//        letras tenga la palabra
//   <X>  la letra         <R>  OK, NO o RPT, siempre tres caracteres
//   <n>  intentos que quedan
//   <E>  WIN, LER o LTO   <W>  la palabra completa
//
// Todas terminan en salto de linea. Los campos son de ancho fijo para
// que el analizador de Python trocee por posicion, sin expresiones
// regulares, y para que aqui solo el patron y la palabra tengan longitud
// variable.
//
// Tambien informa cuantas lineas tiene el evento y cual es el ultimo
// indice de la linea actual, que es lo que la maquina de estados necesita
// para saber cuando avanzar. De esa forma el formato se cambia sin tocar
// la maquina de estados, y al reves.
// =====================================================================

module uart_msg_char_gen #(
    parameter int MAX_LEN = 12
) (
    // datos congelados de la jugada
    input  logic [1:0]           event_i,
    input  logic [7:0]           letter_i,
    input  logic                 hit_i,
    input  logic [1:0]           end_code_i,
    input  logic [8*MAX_LEN-1:0] word_data_i,   // primer caracter en los bits altos
    input  logic [3:0]           word_len_i,
    input  logic [MAX_LEN-1:0]   revealed_i,
    input  logic [2:0]           errors_i,      // errores cometidos, 0 a 6
    input  logic                 mode_i,        // 0 facil, 1 dificil

    // posicion que se quiere consultar
    input  logic [1:0]           line_i,        // linea dentro de la secuencia
    input  logic [4:0]           idx_i,         // byte dentro de la linea

    output logic [7:0]           char_o,        // caracter en esa posicion
    output logic [4:0]           last_idx_o,    // ultimo indice de esta linea
    output logic [1:0]           n_lines_o      
);

    // codigos de evento
    localparam logic [1:0] EV_INICIO   = 2'd0;
    localparam logic [1:0] EV_LETRA    = 2'd1;
    localparam logic [1:0] EV_REPETIDA = 2'd2;
    localparam logic [1:0] EV_FIN      = 2'd3;

    localparam logic [7:0] CAR_LF      = 8'h0A;
    localparam logic [7:0] CAR_DOSP    = 8'h3A;   // ':'
    localparam logic [7:0] CAR_ESPACIO = 8'h20;
    localparam logic [7:0] CAR_GUION   = 8'h5F;   // '_'
    localparam logic [7:0] CAR_CERO    = 8'h30;
    localparam logic [7:0] CAR_UNO     = 8'h31;
    localparam logic [7:0] CAR_D       = 8'h44;
    localparam logic [7:0] CAR_F       = 8'h46;

    localparam int         N_POS   = 16;   // holgura sobre MAX_LEN para el indice
    localparam logic [2:0] MAX_ERR = 3'd6;

    // Prefijos rellenados a ocho caracteres para poder indexarlos todos
    // con el mismo calculo. Nunca se lee mas alla de los dos puntos.
   // "START:  " ocupa 8 caracteres = 64 bits, y el
    // primer caracter del string queda en los bits mas altos del vector
    // (PRE_START[63:56] es la 'S'). Por eso mas abajo, para sacar el
    // caracter numero idx_i, hay que restar desde el extremo alto en vez
    // de sumar desde el bajo.
    localparam logic [63:0] PRE_START = "START:  ";
    localparam logic [63:0] PRE_LET   = "LET:    ";
    localparam logic [63:0] PRE_PATT  = "PATT:   ";
    localparam logic [63:0] PRE_ERR   = "ERR:    ";
    localparam logic [63:0] PRE_END   = "END:    ";

    localparam logic [23:0] RES_OK  = "OK ";
    localparam logic [23:0] RES_NO  = "NO ";
    localparam logic [23:0] RES_RPT = "RPT";
    localparam logic [23:0] FIN_WIN = "WIN";
    localparam logic [23:0] FIN_LER = "LER";
    localparam logic [23:0] FIN_LTO = "LTO";

    // identificador de linea
    localparam logic [2:0] L_START = 3'd0;
    localparam logic [2:0] L_LET   = 3'd1;
    localparam logic [2:0] L_PATT  = 3'd2;
    localparam logic [2:0] L_ERR   = 3'd3;
    localparam logic [2:0] L_END   = 3'd4;

    // ---------------------------------------------------------------
    // Que linea toca
    // ---------------------------------------------------------------
    // line_i (0, 1, 2...) es la posicion dentro de la secuencia de un
    // evento, pero el evento mismo decide que significa cada posicion:
    // para EV_INICIO la linea 0 es START, para EV_LETRA la linea 0 es
    // LET. linea_id traduce esa combinacion (evento, posicion) a un
    // identificador unico de linea, que es lo unico que necesita el
    // resto del modulo para saber que formato aplicar.
    logic [2:0] linea_id;

    // Solo inicio y letra tienen tres lineas (el mensaje principal, el
    // patron y los intentos); repetida y fin caben en una sola.
    assign n_lines_o = ((event_i == EV_INICIO) || (event_i == EV_LETRA)) ? 2'd3 : 2'd1;

    always_comb begin
        unique case (event_i)
            EV_INICIO: begin
                if      (line_i == 2'd0) linea_id = L_START;
                else if (line_i == 2'd1) linea_id = L_PATT;
                else                     linea_id = L_ERR;
            end
            EV_LETRA: begin
                if      (line_i == 2'd0) linea_id = L_LET;
                else if (line_i == 2'd1) linea_id = L_PATT;
                else                     linea_id = L_ERR;
            end
            EV_REPETIDA: linea_id = L_LET;
            EV_FIN:      linea_id = L_END;
            default:     linea_id = L_END;
        endcase
    end

    // longitud de la linea actual
    //
    // Cada longitud se arma sumando "cuanto mide lo fijo" mas "cuanto
    // mide lo variable" (el patron o la palabra), mas uno por el salto
    // de linea final. Por ejemplo PATT: son 5 caracteres del prefijo
    // ("PATT:") mas 1 del propio prefijo que ya cuenta el ':' ... el
    // numero 6 de abajo es literalmente contar "P-A-T-T-:-" y sumarle
    // despues la longitud de la palabra y el salto de linea.
    logic [4:0] len_linea;
    always_comb begin
        unique case (linea_id)
            L_START: len_linea = 5'd11;                        // START:M:LL y salto
            L_LET:   len_linea = 5'd10;                        // LET:X:RRR y salto
            L_PATT:  len_linea = 5'd6 + {1'b0, word_len_i};    // PATT: patron y salto
            L_ERR:   len_linea = 5'd6;                         // ERR:n y salto
            default: len_linea = 5'd9 + {1'b0, word_len_i};    // END:EEE:palabra y salto
        endcase
    end
    // El ultimo indice valido de la linea es un caracter menos que su
    // longitud (los indices empiezan en 0), y ese ultimo caracter
    // siempre resulta ser el salto de linea, como se ve mas abajo en el
    // always_comb final.
    assign last_idx_o = len_linea - 5'd1;

    // ---------------------------------------------------------------
    // Campos variables
    // ---------------------------------------------------------------
    logic [7:0] len_dec, len_uni, dig_intentos;
    logic [2:0] intentos;

    // La longitud nunca pasa de doce, asi que el digito de las decenas
    // sale de una comparacion y no de una division.

    assign len_dec      = (word_len_i >= 4'd10) ? CAR_UNO : CAR_CERO;
    assign len_uni      = CAR_CERO + ((word_len_i >= 4'd10) ? {4'd0, word_len_i - 4'd10}
                                                           : {4'd0, word_len_i});
    assign intentos     = MAX_ERR - errors_i;
    assign dig_intentos = CAR_CERO + {5'b00000, intentos};

    // res3 decide el campo de tres letras de una linea LET: si el
    // evento es una repetida siempre es RPT, sin mirar hit_i; solo si no
    // es repetida importa si hit_i acerto o no.
    logic [23:0] res3, fin3;
    assign res3 = (event_i == EV_REPETIDA) ? RES_RPT : (hit_i ? RES_OK : RES_NO);

    always_comb begin
        unique case (end_code_i)
            2'd0:    fin3 = FIN_WIN;
            2'd1:    fin3 = FIN_LER;
            2'd2:    fin3 = FIN_LTO;
            default: fin3 = FIN_LTO;
        endcase
    end

    // patron y palabra, un caracter por posicion
    //
    // Se arman como arreglos de bytes (uno por posicion) en vez de dejar
    // el calculo dentro del case de mas abajo, para que ese case final
    // trabaje con "patron[pos_patt]" en lugar de con una expresion larga
    // de desplazamiento de bits. Separar "como se arma el dato" de "como
    // se decide que caracter mostrar" hace las dos partes mas cortas de
    // leer por separado.
    logic [7:0] patron  [0:N_POS-1];
    logic [7:0] palabra [0:N_POS-1];

    always_comb begin
        // Primero se llenan las N_POS posiciones con espacios: es el
        // valor por defecto que evita un latch si alguna posicion no se
        // sobrescribe en el segundo for (por ejemplo cuando la palabra
        // real mide menos que N_POS).
        for (int c = 0; c < N_POS; c++) begin
            patron[c]  = CAR_ESPACIO;
            palabra[c] = CAR_ESPACIO;
        end
        // word_data_i trae el primer caracter en los bits mas altos
        // (documentado en el puerto), asi que para leer el caracter en
        // la posicion c hay que ir a la posicion (MAX_LEN-1-c) contada
        // desde el principio del vector. +: 8 toma 8 bits empezando en
        // ese indice y subiendo, que es la forma de indexar un vector
        // ancho con un desplazamiento variable sin usar un rango fijo.
        for (int c = 0; c < MAX_LEN; c++) begin
            palabra[c] = word_data_i[8*(MAX_LEN-1-c) +: 8];
            patron[c]  = revealed_i[c] ? word_data_i[8*(MAX_LEN-1-c) +: 8] : CAR_GUION;
        end
    end

    // ---------------------------------------------------------------
    // Caracter que toca
    // ---------------------------------------------------------------
    // "pre" selecciona cual de los cinco prefijos aplica segun la linea
    // actual. Este case es intencionalmente parecido al que calcula
    // len_linea mas arriba: los dos dependen de linea_id, pero conviene
    // mantenerlos separados porque responden preguntas distintas (que
    // texto va primero / cuanto mide la linea entera), y mezclarlos en
    // un solo case gigante seria mas dificil de revisar.
    logic [63:0] pre;
    always_comb begin
        unique case (linea_id)
            L_START: pre = PRE_START;
            L_LET:   pre = PRE_LET;
            L_PATT:  pre = PRE_PATT;
            L_ERR:   pre = PRE_ERR;
            default: pre = PRE_END;
        endcase
    end

    // base_pre calcula, en bits, donde empieza el caracter numero idx_i
    // dentro del vector de 64 bits del prefijo. Como el primer caracter
    // esta en el extremo alto, hay que restar en vez de sumar: el
    // caracter 0 esta en el bit 56 (64 - 8), el caracter 1 en el bit 48,
    // y asi. "idx_i[2:0] * 8" es lo mismo que "idx_i[2:0] << 3", que es
    // lo que hace el truco de concatenar 3 ceros al final del indice.
    logic [5:0] base_pre;
    logic [7:0] car_pre;
    assign base_pre = 6'd56 - {idx_i[2:0], 3'b000};   // 8*(7 - idx)
    assign car_pre  = pre[base_pre +: 8];

    // Las posiciones dentro del patron y de la palabra se cuentan desde
    // donde empieza cada campo. La resta va en cuatro bits porque el
    // resultado siempre cae por debajo de la longitud maxima.
    //
    // pos_patt e pos_word solo tienen sentido cuando idx_i ya paso el
    // prefijo de su linea (el case de abajo se encarga de eso con sus
    // condiciones "else if"); calcularlos aqui de una vez, aunque a
    // veces el resultado no se use, es mas simple que meter la resta dentro
    // del case y repetirla en cada rama que la necesita.
    logic [3:0] pos_patt, pos_word;

    assign pos_patt = idx_i[3:0] - 4'd5;
    assign pos_word = idx_i[3:0] - 4'd8;

    // Los tres caracteres de cada campo fijo se sacan aqui y no dentro
    // del bloque combinacional, para que ahi se trabaje con nombres en
    // lugar de con trozos del vector.
    logic [7:0] res_c0, res_c1, res_c2, fin_c0, fin_c1, fin_c2;
    assign res_c0 = res3[23:16];
    assign res_c1 = res3[15:8];
    assign res_c2 = res3[7:0];
    assign fin_c0 = fin3[23:16];
    assign fin_c1 = fin3[15:8];
    assign fin_c2 = fin3[7:0];

    // Este es el case principal: recorre cada tipo de linea y, dentro de
    // cada una, una cadena de "si idx_i es esta posicion exacta, este es
    // el caracter" que sigue el orden en que se ve la linea de izquierda
    // a derecha. char_o = CAR_LF al principio del bloque es el valor por
    // defecto para toda posicion que caiga despues del ultimo caracter
    // util de la linea, que es justamente donde debe ir el salto de
    // linea.
    always_comb begin
        char_o = CAR_LF;
        unique case (linea_id)

            // START:<M>:<LL>
            L_START: begin
                if      (idx_i <  5'd6) char_o = car_pre;
                else if (idx_i == 5'd6) char_o = mode_i ? CAR_D : CAR_F;
                else if (idx_i == 5'd7) char_o = CAR_DOSP;
                else if (idx_i == 5'd8) char_o = len_dec;
                else if (idx_i == 5'd9) char_o = len_uni;
                else                    char_o = CAR_LF;
            end

            // LET:<X>:<R>
            L_LET: begin
                if      (idx_i <  5'd4) char_o = car_pre;
                else if (idx_i == 5'd4) char_o = letter_i;
                else if (idx_i == 5'd5) char_o = CAR_DOSP;
                else if (idx_i == 5'd6) char_o = res_c0;
                else if (idx_i == 5'd7) char_o = res_c1;
                else if (idx_i == 5'd8) char_o = res_c2;
                else                    char_o = CAR_LF;
            end

            // PATT:<p>
            L_PATT: begin
                if      (idx_i < 5'd5)  char_o = car_pre;
                else if (idx_i < len_linea - 5'd1) char_o = patron[pos_patt];
                else                    char_o = CAR_LF;
            end

            // ERR:<n>
            L_ERR: begin
                if      (idx_i <  5'd4) char_o = car_pre;
                else if (idx_i == 5'd4) char_o = dig_intentos;
                else                    char_o = CAR_LF;
            end

            // END:<E>:<W>
            default: begin
                if      (idx_i <  5'd4) char_o = car_pre;
                else if (idx_i == 5'd4) char_o = fin_c0;
                else if (idx_i == 5'd5) char_o = fin_c1;
                else if (idx_i == 5'd6) char_o = fin_c2;
                else if (idx_i == 5'd7) char_o = CAR_DOSP;
                else if (idx_i < len_linea - 5'd1) char_o = palabra[pos_word];
                else                    char_o = CAR_LF;
            end
        endcase
    end

endmodule
