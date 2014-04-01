library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

library std;
use std.textio.all;
use std.standard.all;

entity memory is
  port (
    clk  : in  std_logic;
    rst  : in  std_logic;
    addr : in  std_logic_vector(31 downto 0);
    di   : in  std_logic_vector(31 downto 0);
    do   : out std_logic_vector(31 downto 0);
    we   : in  std_logic
    );
end memory;

architecture Behavioral of memory is
  constant C_MEM_SIZE : natural := 4*1024;  -- 0x00000000 ... 0x00001000
  type     MEM_T is array (0 to C_MEM_SIZE-1) of std_logic_vector(31 downto 0);
  signal   mem        : MEM_T;

  type t_char_file is file of character;
  file file_in : t_char_file open read_mode is "./partial_add.bit";  -- open the frame file for reading
begin

  do <= mem(CONV_INTEGER(addr));

  process(clk, rst)
    variable char_buffer0 : character;
    variable char_buffer1 : character;
    variable char_buffer2 : character;
    variable char_buffer3 : character;
    variable i           : natural := 0;
  begin
    if rising_edge(clk) then
      if rst = '1' then
        --for i in 0 to C_MEM_SIZE-1 loop
        --  mem(i) <= x"DA" & CONV_STD_LOGIC_VECTOR(C_MEM_SIZE-1 - i, 24);  -- 0x00000FFF ... 0x00000000; sort: 0x00000FFF ... 0x00000800
        --end loop;
        -----------------------------------------------------------------------------
        -- read from bit file and place it in memory
        -----------------------------------------------------------------------------
        readLoop : while not (endfile(file_in)) and i < C_MEM_SIZE loop
          read(file_in, char_buffer0);
          read(file_in, char_buffer1);
          read(file_in, char_buffer2);
          read(file_in, char_buffer3);
          mem(CONV_INTEGER(i)) <= std_logic_vector(conv_std_logic_vector(character'pos(char_buffer0), 8)) &
                                  std_logic_vector(conv_std_logic_vector(character'pos(char_buffer1), 8)) &
                                  std_logic_vector(conv_std_logic_vector(character'pos(char_buffer2), 8)) &
                                  std_logic_vector(conv_std_logic_vector(character'pos(char_buffer3), 8));

          i := i + 1;
        end loop readLoop;

      elsif we = '1' then
        mem(CONV_INTEGER(addr)) <= di;
      end if;
    end if;
  end process;

end Behavioral;
