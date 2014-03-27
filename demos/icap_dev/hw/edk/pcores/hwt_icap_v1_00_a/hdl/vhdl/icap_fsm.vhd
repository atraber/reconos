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
    DonexSO       : out std_logic;
    ErrorxSO      : out std_logic;
    LenxDI        : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
    RamAddrxDO    : out std_logic_vector(ADDR_WIDTH-1 downto 0);
    ICAPCExSI     : in  std_logic;
    ICAPStatusxDI : in  std_logic_vector(0 to 31)
    );

end ICAPFsm;


architecture implementation of ICAPFsm is
  type state_t is (STATE_IDLE, STATE_WRITE, STATE_CHECK, STATE_FINISH, STATE_ERROR);

  -- signals
  signal AddrxDP, AddrxDN   : unsigned(ADDR_WIDTH-1 downto 0);
  signal StatexDP, StatexDN : state_t;

  signal ICAPCExS    : std_logic;
  signal DonexS      : std_logic;
  signal ErrorxS     : std_logic;
  signal ICAPErrorxS : std_logic;       -- is set to 1 if ICAPStatus indicates
                                        -- an error

begin  -- implementation

  -----------------------------------------------------------------------------
  -- registers
  -----------------------------------------------------------------------------

  regFF : process (ClkxCI, ResetxRI)
  begin  -- process regFF
    if ResetxRI = '1' then              -- asynchronous reset (active high)
      StatexDP <= STATE_IDLE;
      AddrxDP  <= unsigned(conv_std_logic_vector(0, AddrxDP'length));
    elsif ClkxCI'event and ClkxCI = '1' then  -- rising clock edge
      StatexDP <= StatexDN;
      AddrxDP  <= AddrxDN;
    end if;
  end process regFF;

  -----------------------------------------------------------------------------
  -- ICAP FSM
  -----------------------------------------------------------------------------

  icapFSM : process (AddrxDP, ICAPErrorxS, LenxDI, StartxSI, StatexDP)
  begin  -- process icapFSM
    StatexDN <= StatexDP;
    AddrxDN  <= AddrxDP;
    ICAPCExS <= '0';
    DonexS   <= '0';
    ErrorxS  <= '0';


    case StatexDP is
      -------------------------------------------------------------------------
      -- idle state, wait for start signal
      -------------------------------------------------------------------------
      when STATE_IDLE =>
        AddrxDN <= unsigned(conv_std_logic_vector(0, AddrxDP'length));

        if StartxSI = '1' then
          StatexDN <= STATE_WRITE;
        end if;

        -------------------------------------------------------------------------
        -- Write to ICAP
        -------------------------------------------------------------------------
      when STATE_WRITE =>
        ICAPCExS <= '1';
        AddrxDN  <= AddrxDP + 1;

        if ICAPErrorxS = '1' then
          StatexDN <= STATE_ERROR;
        end if;

        if std_logic_vector(AddrxDP) = LenxDI then
          StatexDN <= STATE_CHECK;
        end if;

        -----------------------------------------------------------------------
        -- Check if an error occurred on last write cycle
        -----------------------------------------------------------------------
      when STATE_CHECK =>
        if ICAPErrorxS = '1' then
          StatexDN <= STATE_ERROR;
        else
          StatexDN <= STATE_FINISH;
        end if;

        -----------------------------------------------------------------------
        -- We have finished processing this chunk of data, set DonexS to high
        -----------------------------------------------------------------------
      when STATE_FINISH =>
        DonexS <= '1';

        StatexDN <= STATE_IDLE;

        -----------------------------------------------------------------------
        -- An error occurred, set ErrorxS to high
        -----------------------------------------------------------------------
      when STATE_ERROR =>
        ErrorxS <= '1';

        StatexDN <= STATE_IDLE;

        -------------------------------------------------------------------------
        -- default case, will never be reached, do nothing
        -------------------------------------------------------------------------
      when others => null;
    end case;
  end process icapFSM;


  -----------------------------------------------------------------------------
  -- signal assignments
  -----------------------------------------------------------------------------
  ICAPErrorxS <= ICAPStatusxDI(7);

  -----------------------------------------------------------------------------
  -- output assignments
  -----------------------------------------------------------------------------
  ErrorxSO <= ErrorxS;
  DonexSO  <= DonexS;

end implementation;
