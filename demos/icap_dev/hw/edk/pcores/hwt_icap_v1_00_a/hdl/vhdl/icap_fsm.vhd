-------------------------------------------------------------------------------
-- Title      : ICAP FSM
-- Project    : 
-------------------------------------------------------------------------------
-- File       : icap_fsm.vhd
-- Author     : atraber  <atraber@student.ethz.ch>
-- Company    : Computer Engineering and Networks Laboratory, ETH Zurich
-- Created    : 2014-04-07
-- Last update: 2014-04-10
-- Platform   : Xilinx ISIM (simulation), Xilinx (synthesis)
-- Standard   : VHDL'87
-------------------------------------------------------------------------------
-- Description: This FSM is responsible to transfer data from the local RAM to
-- the ICAP interface.
-------------------------------------------------------------------------------
-- Copyright (c) 2014 Computer Engineering and Networks Laboratory, ETH Zurich
-------------------------------------------------------------------------------
-- Revisions  :
-- Date        Version  Author  Description
-- 2014-04-07  1.0      atraber Created
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

entity ICAPFsm is

  generic (
    ADDR_WIDTH : natural := 32
    );

  port (
    ClkxCI        : in  std_logic;
    ResetxRI      : in  std_logic;
    StartxSI      : in  std_logic;
    AckxSI        : in  std_logic;
    DonexSO       : out std_logic;
    ErrorxSO      : out std_logic;
    LenxDI        : in  std_logic_vector(0 to ADDR_WIDTH-1);
    UpperxSI      : in  std_logic;
    RamAddrxDO    : out std_logic_vector(0 to ADDR_WIDTH-1);
    RamLutMuxxSO  : out std_logic;      -- 0 means Ram, 1 means Lut
    ICAPCExSBO    : out std_logic;
    ICAPWExSBO    : out std_logic;
    ICAPStatusxDI : in  std_logic_vector(0 to 31)
    );

end ICAPFsm;


architecture implementation of ICAPFsm is
  type state_t is (STATE_IDLE, STATE_WRITE_WAIT, STATE_WRITE, STATE_FINISH, STATE_ERROR,
                   STATE_CRCCHECK, STATE_CRCRESET, STATE_CRCRESET_WAIT);

  -----------------------------------------------------------------------------
  -- signals
  -----------------------------------------------------------------------------

  -- registers
  signal AddrxDP, AddrxDN   : unsigned(ADDR_WIDTH-1 downto 0);
  signal StatexDP, StatexDN : state_t;
  signal LenxDP, LenxDN     : std_logic_vector(0 to ADDR_WIDTH-1);
  signal UpperxSP, UpperxSN : std_logic;
  signal ICAPCExSB          : std_logic;
  signal ICAPWExSB          : std_logic;
  signal RamLutMuxxS        : std_logic;

  -- ordinary signals
  signal DonexS      : std_logic;
  signal ErrorxS     : std_logic;
  signal ICAPErrorxS : std_logic;  -- set to 1 if ICAPStatus indicates an error
  signal ICAPSyncxS  : std_logic;  -- set to 1 if ICAPStatus indicates that we are synced
begin  -- implementation

  -----------------------------------------------------------------------------
  -- registers
  -----------------------------------------------------------------------------

  regFF : process (ClkxCI, ResetxRI)
  begin  -- process regFF
    if ResetxRI = '1' then              -- asynchronous reset (active high)
      StatexDP <= STATE_IDLE;
      AddrxDP  <= unsigned(conv_std_logic_vector(0, AddrxDP'length));
      LenxDP   <= (others => '0');
      UpperxSP <= '0';
    elsif ClkxCI'event and ClkxCI = '1' then  -- rising clock edge
      StatexDP <= StatexDN;
      AddrxDP  <= AddrxDN;
      LenxDP   <= LenxDN;
      UpperxSP <= UpperxSN;
    end if;
  end process regFF;

  -----------------------------------------------------------------------------
  -- ICAP FSM
  -----------------------------------------------------------------------------

  icapFSM : process (AckxSI, AddrxDN, AddrxDP, ICAPErrorxS, ICAPSyncxS, LenxDI,
                     LenxDP, StartxSI, StatexDP, UpperxSI, UpperxSP)
  begin  -- process icapFSM
    StatexDN    <= StatexDP;
    AddrxDN     <= AddrxDP;
    LenxDN      <= LenxDP;
    UpperxSN    <= UpperxSP;
    RamLutMuxxS <= '0';                 -- RAM
    ICAPCExSB   <= '1';                 -- active low, so not active here
    ICAPWExSB   <= '0';                 -- active low, doing a write
    DonexS      <= '0';
    ErrorxS     <= '0';


    case StatexDP is
      -------------------------------------------------------------------------
      -- idle state, wait for start signal
      -------------------------------------------------------------------------
      when STATE_IDLE =>
        AddrxDN <= unsigned(conv_std_logic_vector(0, AddrxDP'length));

        if StartxSI = '1' then
          StatexDN <= STATE_WRITE_WAIT;
          UpperxSN <= UpperxSI;
          LenxDN   <= LenxDI;
        end if;

        -------------------------------------------------------------------------
        -- Write to ICAP, make sure that first address is applied
        -------------------------------------------------------------------------
      when STATE_WRITE_WAIT =>
        AddrxDN <= AddrxDP + 1;

        StatexDN <= STATE_WRITE;

        -------------------------------------------------------------------------
        -- Write to ICAP
        -------------------------------------------------------------------------
      when STATE_WRITE =>
        ICAPCExSB <= '0';               -- active low
        ICAPWExSB <= '0';               -- active low
        AddrxDN   <= AddrxDP + 1;

        if ICAPErrorxS = '1' then
          StatexDN <= STATE_CRCCHECK;
        else
          if std_logic_vector(AddrxDP) = LenxDP then
            StatexDN <= STATE_CRCCHECK;
          end if;
        end if;

        -----------------------------------------------------------------------
        -- Check if an error occurred on last write cycle, and if yes, we go
        -- ahead and reset this error so that we have are in a clean state once
        -- again
        -----------------------------------------------------------------------
      when STATE_CRCCHECK =>
        if ICAPErrorxS = '1' then
          if ICAPSyncxS = '1' then
            AddrxDN <= unsigned(conv_std_logic_vector(5, AddrxDP'length));
          else
            AddrxDN <= unsigned(conv_std_logic_vector(0, AddrxDP'length));
          end if;

          StatexDN <= STATE_CRCRESET_WAIT;
        else
          StatexDN <= STATE_FINISH;
        end if;

        -----------------------------------------------------------------------
        -- Wait one cycle for RAM before starting with CRC reset on ICAP interface
        -----------------------------------------------------------------------
      when STATE_CRCRESET_WAIT =>
        AddrxDN <= AddrxDP + 1;

        StatexDN <= STATE_CRCRESET;

        -----------------------------------------------------------------------
        -- Reset CRC on ICAP interface
        -----------------------------------------------------------------------
      when STATE_CRCRESET =>
        ICAPCExSB   <= '0';             -- active low
        RamLutMuxxS <= '1';             -- LUT active
        AddrxDN     <= AddrxDP + 1;

        if AddrxDP = 13 then
          StatexDN <= STATE_ERROR;
        end if;


        -----------------------------------------------------------------------
        -- We have finished processing this chunk of data, set DonexS to high
        -- We wait for AckxSI = '1' as otherwise it could happen that our
        -- controlling FSM misses the Done signal
        -----------------------------------------------------------------------
      when STATE_FINISH =>
        DonexS <= '1';

        if AckxSI = '1' then
          StatexDN <= STATE_IDLE;
        end if;

        -----------------------------------------------------------------------
        -- An error occurred, set ErrorxS to high
        -- We wait for AckxSI = '1' as otherwise it could happen that our
        -- controlling FSM misses the Error signal
        -----------------------------------------------------------------------
      when STATE_ERROR =>
        ErrorxS <= '1';

        if AckxSI = '1' then
          StatexDN <= STATE_IDLE;
        end if;

        -------------------------------------------------------------------------
        -- default case, will never be reached, do nothing
        -------------------------------------------------------------------------
      when others => null;
    end case;
  end process icapFSM;

  -----------------------------------------------------------------------------
  -- signal assignments
  -----------------------------------------------------------------------------
  ICAPErrorxS <= not ICAPStatusxDI(24);
  ICAPSyncxS  <= ICAPStatusxDI(25);

  -----------------------------------------------------------------------------
  -- output assignments
  -----------------------------------------------------------------------------
  ErrorxSO     <= ErrorxS;
  DonexSO      <= DonexS;
  ICAPCExSBO   <= ICAPCExSB;
  ICAPWExSBO   <= ICAPWExSB;
  RamLutMuxxSO <= RamLutMuxxS;

  RamAddrxDO <= std_logic_vector(UpperxSP & AddrxDP(ADDR_WIDTH-2 downto 0));

end implementation;
