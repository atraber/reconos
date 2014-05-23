library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

library UNISIM;
use UNISIM.vcomponents.all;

entity clock_enable is
  port (
    clk     : in  std_logic;
    clk_en  : in  std_logic;
    clk_out : out std_logic
    );
end entity;

architecture implementation of clock_enable is
begin

--  BUFR_inst : BUFR
--     generic map (
--       BUFR_DIVIDE => "1",  -- Defines whether the output clock is a divided version of input clock.
--       SIM_DEVICE  => "VIRTEX6"
--       )
--     port map
--     (  -- 1-bit Clock output port. This port drives the clock tracks in the clock region of the BUFR
--       -- and the two adjacent clock regions. This port drives FPGA fabric, and IOBs.
--       O   => clk_out,
--       -- 1-bit Clock enable port. When asserted Low, this port disables the output clock at port O.
--       -- When asserted High, this port resets the counter used to produce the divided clock output.
--       CE  => clk_en,
--       -- 1-bit Counter reset for divided clock output. When asserted High, this port resets the
--       -- counter used to produce the divided clock output.
--       CLR => '0',
--       -- 1-bit Clock input port. This port is the clock source port for BUFR. It can be driven by
--       -- BUFIO output or local interconnect.
--       I   => clk
--       );

  BUFHCE_inst : BUFHCE
    generic map (
      INIT_OUT => 0  -- Initial output value, also indicates stop low vs stop high behavior
      )
    port map (
      O  => clk_out,                    -- 1-bit The output of the BUFH
      CE => clk_en,  -- 1-bit Enables propagation of signal from I to O. When low, sets output to 0.
      I  => clk                         -- 1-bit The input to the BUFH
      );



end architecture;
