library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_textio.all;  -- read and write overloaded for std_logic
use ieee.numeric_std.all;

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
  constant C_MEM_SIZE : natural := 2048;
  constant C_ADDRESS_WIDTH : integer := 11; -- TODO: clog2(C_MEM_SIZE);
  type     MEM_T is array (0 to C_MEM_SIZE-1) of std_logic_vector(31 downto 0);
  signal   mem        : MEM_T;

  signal memFirstValid : integer := 0;
  signal memLastValid  : integer := 0;

  file file_in : text open read_mode is "./partial_add.hex";  -- open the frame file for reading
begin

  do <= mem(to_integer(unsigned(addr(C_ADDRESS_WIDTH-1 downto 0))));

  process(clk, rst)
    variable i       : natural := 0;
    variable line    : line;
    variable vec     : std_logic_vector(0 to 31);
    variable read_ok : boolean;
  begin
    if rising_edge(clk) then

      if addr /= "UUUUUUUUUUUUUUUUUUUUUUUUUUUUUUUU" and to_integer(unsigned(addr)) < memFirstValid then
        report "Memory access does not seem to be sequential, only sequential memory access is supported"
          severity failure;
      end if;

      if to_integer(unsigned(addr)) >= memLastValid and not (endfile(file_in)) then
        -----------------------------------------------------------------------------
        -- read from bit file and place it in memory
        -----------------------------------------------------------------------------
        i := 0;

        readLoop : while not (endfile(file_in)) and i < C_MEM_SIZE loop
          readline(file_in, line);
          hread(line, vec, read_ok);
          mem(i) <= vec;

          i := i + 1;
        end loop readLoop;

        -- TODO
--        if to_integer(unsigned(addr)) >= memLastvalid + i then
--          report "Memory access does not seem to be sequential, only sequential memory access is supported"
--            severity failure;
--        end if;

        memFirstValid <= memLastValid;
        memLastValid  <= memLastValid + i;

        report "Memory reloaded" severity note;
      end if;

      if rst = '1' then

      elsif we = '1' then
        mem(to_integer(unsigned(addr))) <= di;
      end if;

    end if;
  end process;

end Behavioral;
