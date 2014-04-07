-------------------------------------------------------------------------------
-- Title      : Simple ICAP Interface Simulation Model
-- Project    : Partial Reconfiguration
-------------------------------------------------------------------------------
-- File       : icap_sim.vhd
-- Author     : atraber  <atraber@student.ethz.ch>
-- Company    : Computer Engineering and Networks Laboratory, ETH Zurich
-- Created    : 2014-04-04
-- Last update: 2014-04-07
-- Platform   : Xilinx ISIM (simulation), Xilinx (synthesis)
-- Standard   : VHDL'87
-------------------------------------------------------------------------------
-- Description: This very basic simulation model is by no means complete and
-- only supports a very limited feature set.
--
-- Limitations include:
--  - Only 32 bit width
--  - Obviously no actual reconfiguration is done
--  - No guarantee that it is cycle accurate for every command...
-------------------------------------------------------------------------------
-- Copyright (c) 2014 Computer Engineering and Networks Laboratory, ETH Zurich
-------------------------------------------------------------------------------
-- Revisions  :
-- Date        Version  Author  Description
-- 2014-04-04  1.0      atraber Created
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_textio.all;  -- read and write overloaded for std_logic
use ieee.numeric_std.all;

library std;
use std.textio.all;
use std.standard.all;

entity ICAPWrapper is
  generic (
    ICAP_WIDTH : natural := 32
    );

  port (
    clk   : in  std_logic;
    csb   : in  std_logic;
    rdwrb : in  std_logic;
    i     : in  std_logic_vector(0 to 31);
    busy  : out std_logic;
    o     : out std_logic_vector(0 to 31)
    );

end ICAPWrapper;

architecture behavioral of ICAPWrapper is
  -----------------------------------------------------------------------------
  -- constants
  -----------------------------------------------------------------------------
  constant STATUS_IDLE      : std_logic_vector(0 to 31) := x"FFFFFF9F";  -- x"F9FFFFFF";
  constant STATUS_SYNC      : std_logic_vector(0 to 31) := x"FFFFFFDF";  -- x"FBFFFFFF";
  constant STATUS_SYNCERR   : std_logic_vector(0 to 31) := x"FFFFFF5F";  -- x"FAFFFFFF";
  constant STATUS_NOSYNCERR : std_logic_vector(0 to 31) := x"FFFFFF1F";  -- x"F8FFFFFF";

  -----------------------------------------------------------------------------
  -- signals
  -----------------------------------------------------------------------------
  signal DataInxD : std_logic_vector(0 to 31);
  signal OutxD    : std_logic_vector(0 to 31);

  -----------------------------------------------------------------------------
  -- files
  -----------------------------------------------------------------------------
  file file_in : text open read_mode is "./partial_check.hex";  -- open the frame file for reading

  -----------------------------------------------------------------------------
  -- functions
  -----------------------------------------------------------------------------
  function to_hex_string(s : in std_logic_vector)
    return string
  is
    variable result : string (1 to s'length/4);
    --- A subtype to keep the VHDL compiler happy
    --- (the rules about data types in a CASE are quite strict)
    subtype  slv4 is std_logic_vector(1 to 4);
  begin
    assert (s'length mod 4) = 0
      report "SLV must be a multiple of 4 bits"
      severity failure;
    for i in 0 to s'length/4-1 loop
      case slv4'(s(i*4 to i*4+3)) is
        when "0000" => result(i+1) := '0';
        when "0001" => result(i+1) := '1';
        when "0010" => result(i+1) := '2';
        when "0011" => result(i+1) := '3';
        when "0100" => result(i+1) := '4';
        when "0101" => result(i+1) := '5';
        when "0110" => result(i+1) := '6';
        when "0111" => result(i+1) := '7';
        when "1000" => result(i+1) := '8';
        when "1001" => result(i+1) := '9';
        when "1010" => result(i+1) := 'A';
        when "1011" => result(i+1) := 'B';
        when "1100" => result(i+1) := 'C';
        when "1101" => result(i+1) := 'D';
        when "1110" => result(i+1) := 'E';
        when "1111" => result(i+1) := 'F';
        when others => result(i+1) := 'x';
      end case;
    end loop;
    return result;
  end;
begin  -- behavioral

  checkResp : process
    variable j       : natural := 0;
    variable line    : line;
    variable vec     : std_logic_vector(0 to 31);
    variable read_ok : boolean;

    variable wasCmd : boolean := false;
  begin  -- process checkResp
    busy  <= '1';
    OutxD <= STATUS_IDLE;

    L1 : loop
      wait until rising_edge(clk);

      if csb = '0' and rdwrb = '0' then
        busy <= '0';

        -----------------------------------------------------------------------
        -- check responses
        -----------------------------------------------------------------------
        readline(file_in, line);
        hread(line, vec, read_ok);

        if DataInxD /= vec then
          report "bitstream not equal, is " & to_hex_string(DataInxD)
            & " while expected " & to_hex_string(vec) severity note;

          if OutxD = STATUS_SYNC then
            OutxD <= STATUS_SYNCERR;
          elsif OutxD = STATUS_IDLE then
            OutxD <= STATUS_NOSYNCERR;  -- not actually possible but useful for debugging
          end if;
        end if;

        if endfile(file_in) then
          report "End of File reached, finished loading bitfile" severity note;
        end if;


        -----------------------------------------------------------------------
        -- react to commands from bitfile
        -----------------------------------------------------------------------
        if wasCmd then
          -- check for desync
          if DataInxD = x"0000000D" then
            OutxD <= STATUS_IDLE;       -- does not yet work
            report "desync received" severity note;
          elsif DataInxD = x"00000007" then
            OutxD <= STATUS_SYNC;
            report "RCRC received" severity note;
          end if;
        end if;
        wasCmd := false;

        -- check for type 1, cmd reg
        if DataInxD = x"30008001" then
          wasCmd := true;
          report "type 1, cmd reg received" severity note;
        elsif DataInxD = x"AA995566" then
          if OutxD = STATUS_IDLE then
            OutxD <= STATUS_SYNC;
          elsif OutxD = STATUS_NOSYNCERR then
            OutxD <= STATUS_SYNCERR;
          end if;
          report "sync word received" severity note;
        end if;

        j := j + 1;
      else
        busy <= '1';
      end if;

      
    end loop;
  end process checkResp;

  -----------------------------------------------------------------------------
  -- signal assignments
  -----------------------------------------------------------------------------

  -- ICAP input is bit swapped, so swap it back so that we can use it
  swapGen : for k in 0 to 3 generate
    bitSwapGen : for j in 0 to 7 generate
      DataInxD(k * 8 + j) <= i((k + 1) * 8 - 1 - j);
    end generate bitSwapGen;
  end generate swapGen;


  -----------------------------------------------------------------------------
  -- output assignments
  -----------------------------------------------------------------------------
  o <= OutxD;

end behavioral;
