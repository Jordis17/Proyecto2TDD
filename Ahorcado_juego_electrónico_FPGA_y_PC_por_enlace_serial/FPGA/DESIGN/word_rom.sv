// =====================================================================
// word_rom.sv - Banco de 64 palabras del Ahorcado

// Orden del banco de palabras
//   indices  0..31 -> longitud >= 6 (pueden ser seleccionadas para el modo DIFICIL y para el modo FACIL)
//   indices 32..63 -> longitud 4 o 5      (unicamente seleccionadas para el modo FACIL)
//
// Lectura combinacional; el sistema guarda la palabra en un registro cuando la partida esta en estado de START_GAME.
// =====================================================================

module word_rom 
(
    input  logic [64-1:0] index_i,
    output logic [96-1:0]  word_data_o,
    output logic [3:0]  word_len_o   //longitud de la palabra en caracteres (4 bits son suficientes para representar 0..12)
);
    /* Empaquetado de la palabra:
       Cada entrada de la ROM entrega la palabra completa con longitud variable en el vector binario de salida word_data_o.
       Para facilitar lectura de código la primera letra de la palabra se ubica en el bit más significativo, en caso de que la 
       palabra sea más corta que MAX_LEN, los espacios restantes se rellanan con espacios en blanco.
    */
    always_comb begin
        unique case (index_i)

        //Banco de palabras clasificadas como dificiles (longitud >= 6)
            6'd0  : begin word_data_o = "PUERTA      "; word_len_o = 4'd6 ; end  
            6'd1  : begin word_data_o = "SENSOR      "; word_len_o = 4'd6 ; end  
            6'd2  : begin word_data_o = "VOLCAN      "; word_len_o = 4'd6 ; end  
            6'd3  : begin word_data_o = "MADERA      "; word_len_o = 4'd6 ; end  
            6'd4  : begin word_data_o = "CAMISA      "; word_len_o = 4'd6 ; end  
            6'd5  : begin word_data_o = "BOTELLA     "; word_len_o = 4'd7 ; end  
            6'd6  : begin word_data_o = "VENTANA     "; word_len_o = 4'd7 ; end  
            6'd7  : begin word_data_o = "TECLADO     "; word_len_o = 4'd7 ; end  
            6'd8  : begin word_data_o = "MONITOR     "; word_len_o = 4'd7 ; end  
            6'd9  : begin word_data_o = "MEMORIA     "; word_len_o = 4'd7 ; end  
            6'd10 : begin word_data_o = "SISTEMA     "; word_len_o = 4'd7 ; end 
            6'd11 : begin word_data_o = "DIGITAL     "; word_len_o = 4'd7 ; end  
            6'd12 : begin word_data_o = "LAMPARA     "; word_len_o = 4'd7 ; end  
            6'd13 : begin word_data_o = "ESCUELA     "; word_len_o = 4'd7 ; end  
            6'd14 : begin word_data_o = "PLANETA     "; word_len_o = 4'd7 ; end  
            6'd15 : begin word_data_o = "CIRCUITO    "; word_len_o = 4'd8 ; end  
            6'd16 : begin word_data_o = "REGISTRO    "; word_len_o = 4'd8 ; end  
            6'd17 : begin word_data_o = "CONTADOR    "; word_len_o = 4'd8 ; end  
            6'd18 : begin word_data_o = "GUITARRA    "; word_len_o = 4'd8 ; end  
            6'd19 : begin word_data_o = "ELEFANTE    "; word_len_o = 4'd8 ; end  
            6'd20 : begin word_data_o = "MARIPOSA    "; word_len_o = 4'd8 ; end  
            6'd21 : begin word_data_o = "TELEFONO    "; word_len_o = 4'd8 ; end  
            6'd22 : begin word_data_o = "PANTALLA    "; word_len_o = 4'd8 ; end 
            6'd23 : begin word_data_o = "CUADERNO    "; word_len_o = 4'd8 ; end  
            6'd24 : begin word_data_o = "BICICLETA   "; word_len_o = 4'd9 ; end 
            6'd25 : begin word_data_o = "INGENIERO   "; word_len_o = 4'd9 ; end  
            6'd26 : begin word_data_o = "MICROFONO   "; word_len_o = 4'd9 ; end  
            6'd27 : begin word_data_o = "VENTILADOR  "; word_len_o = 4'd10; end  
            6'd28 : begin word_data_o = "COMPUTADORA "; word_len_o = 4'd11; end  
            6'd29 : begin word_data_o = "LABORATORIO "; word_len_o = 4'd11; end  
            6'd30 : begin word_data_o = "HERRAMIENTA "; word_len_o = 4'd11; end  
            6'd31 : begin word_data_o = "RESISTENCIA "; word_len_o = 4'd11; end  

        //Banco de palabras faciles (longitud 4 o 5)    
            6'd32 : begin word_data_o = "CASA        "; word_len_o = 4'd4 ; end  
            6'd33 : begin word_data_o = "MESA        "; word_len_o = 4'd4 ; end  
            6'd34 : begin word_data_o = "SILLA       "; word_len_o = 4'd5 ; end  
            6'd35 : begin word_data_o = "LIBRO       "; word_len_o = 4'd5 ; end  
            6'd36 : begin word_data_o = "PERRO       "; word_len_o = 4'd5 ; end  
            6'd37 : begin word_data_o = "GATO        "; word_len_o = 4'd4 ; end  
            6'd38 : begin word_data_o = "LUNA        "; word_len_o = 4'd4 ; end  
            6'd39 : begin word_data_o = "NUBE        "; word_len_o = 4'd4 ; end  
            6'd40 : begin word_data_o = "FLOR        "; word_len_o = 4'd4 ; end  
            6'd41 : begin word_data_o = "ARBOL       "; word_len_o = 4'd5 ; end 
            6'd42 : begin word_data_o = "CIELO       "; word_len_o = 4'd5 ; end  
            6'd43 : begin word_data_o = "FUEGO       "; word_len_o = 4'd5 ; end  
            6'd44 : begin word_data_o = "AGUA        "; word_len_o = 4'd4 ; end  
            6'd45 : begin word_data_o = "VERDE       "; word_len_o = 4'd5 ; end  
            6'd46 : begin word_data_o = "ROJO        "; word_len_o = 4'd4 ; end  
            6'd47 : begin word_data_o = "AZUL        "; word_len_o = 4'd4 ; end  
            6'd48 : begin word_data_o = "NEGRO       "; word_len_o = 4'd5 ; end  
            6'd49 : begin word_data_o = "CINCO       "; word_len_o = 4'd5 ; end  
            6'd50 : begin word_data_o = "TRES        "; word_len_o = 4'd4 ; end  
            6'd51 : begin word_data_o = "SIETE       "; word_len_o = 4'd5 ; end  
            6'd52 : begin word_data_o = "OCHO        "; word_len_o = 4'd4 ; end  
            6'd53 : begin word_data_o = "NUEVE       "; word_len_o = 4'd5 ; end  
            6'd54 : begin word_data_o = "LAPIZ       "; word_len_o = 4'd5 ; end  
            6'd55 : begin word_data_o = "PAPEL       "; word_len_o = 4'd5 ; end  
            6'd56 : begin word_data_o = "CABLE       "; word_len_o = 4'd5 ; end  
            6'd57 : begin word_data_o = "DATOS       "; word_len_o = 4'd5 ; end  
            6'd58 : begin word_data_o = "RELOJ       "; word_len_o = 4'd5 ; end  
            6'd59 : begin word_data_o = "CHIP        "; word_len_o = 4'd4 ; end  
            6'd60 : begin word_data_o = "PUNTO       "; word_len_o = 4'd5 ; end  
            6'd61 : begin word_data_o = "CAMPO       "; word_len_o = 4'd5 ; end 
            6'd62 : begin word_data_o = "PLAYA       "; word_len_o = 4'd5 ; end  
            6'd63 : begin word_data_o = "BARCO       "; word_len_o = 4'd5 ; end  
            default: begin word_data_o = "            "; word_len_o = 4'd0;  end
        endcase
    end

endmodule