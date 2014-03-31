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
    LenxDI        : in  std_logic_vector(0 to ADDR_WIDTH-1);
    RamAddrxDO    : out std_logic_vector(0 to ADDR_WIDTH-1);
    ICAPCExSBO    : out std_logic;
    ICAPWExSBO    : out std_logic;
    ICAPStatusxDI : in  std_logic_vector(0 to 31)
    );

end ICAPFsm;


architecture implementation of ICAPFsm is
  type state_t is (STATE_IDLE, STATE_WRITE, STATE_CHECK, STATE_FINISH, STATE_ERROR, STATE_WAIT,
                   STATE_ABORT0, STATE_ABORT1);        -- TODO: remove abort!

  -- signals
  signal AddrxDP, AddrxDN   : unsigned(ADDR_WIDTH-1 downto 0);
  signal StatexDP, StatexDN : state_t;

  signal ICAPCExSB   : std_logic;
  signal ICAPWExSB   : std_logic;
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
    StatexDN  <= StatexDP;
    AddrxDN   <= AddrxDP;
    ICAPCExSB <= '1';                   -- active low, so not active here
    ICAPWExSB <= '0';                   -- active low, doing a write
    DonexS    <= '0';
    ErrorxS   <= '0';


    case StatexDP is
      -------------------------------------------------------------------------
      -- DEBUG, TODO: REMOVE
      -------------------------------------------------------------------------
      when STATE_ABORT0 =>
        ICAPCExSB <= '0';
        StatexDN <= STATE_ABORT1;

      -------------------------------------------------------------------------
      -- DEBUG, TODO: REMOVE
      -------------------------------------------------------------------------
      when STATE_ABORT1 =>
        ICAPCExSB <= '0';
        ICAPWExSB <= '1';
        StatexDN <= STATE_WRITE;

      -------------------------------------------------------------------------
      -- wait state, we wait one cycle before going to state IDLE as otherwise
      -- we would need probably create a mealy machine, which is something we
      -- want to avoid
      -------------------------------------------------------------------------
      when STATE_WAIT =>
        StatexDN <= STATE_IDLE;

        -------------------------------------------------------------------------
        -- idle state, wait for start signal
        -------------------------------------------------------------------------
      when STATE_IDLE =>
        AddrxDN <= unsigned(conv_std_logic_vector(0, AddrxDP'length));

        if StartxSI = '1' then
          StatexDN <= STATE_ABORT0;
        end if;

        -------------------------------------------------------------------------
        -- Write to ICAP
        -------------------------------------------------------------------------
      when STATE_WRITE =>
        ICAPCExSB <= '0';               -- active low
        AddrxDN   <= AddrxDP + 1;

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

        StatexDN <= STATE_WAIT;

        -----------------------------------------------------------------------
        -- An error occurred, set ErrorxS to high
        -----------------------------------------------------------------------
      when STATE_ERROR =>
        ErrorxS <= '1';

        StatexDN <= STATE_WAIT;

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
  ICAPCExSBO  <= ICAPCExSB;
  ICAPWExSBO  <= ICAPWExSB;

  -----------------------------------------------------------------------------
  -- output assignments
  -----------------------------------------------------------------------------
  ErrorxSO   <= ErrorxS;
  DonexSO    <= DonexS;
  RamAddrxDO <= std_logic_vector(AddrxDP);

end implementation;
