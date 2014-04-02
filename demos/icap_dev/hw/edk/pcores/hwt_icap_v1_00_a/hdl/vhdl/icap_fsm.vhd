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
    ModexSI       : in  std_logic;      -- '0' means write, '1' means abort
    DonexSO       : out std_logic;
    ErrorxSO      : out std_logic;
    LenxDI        : in  std_logic_vector(0 to ADDR_WIDTH);
    RamAddrxDO    : out std_logic_vector(0 to ADDR_WIDTH-1);
    ICAPCExSBO    : out std_logic;
    ICAPWExSBO    : out std_logic;
    ICAPStatusxDI : in  std_logic_vector(0 to 31)
    );

end ICAPFsm;


architecture implementation of ICAPFsm is
  type state_t is (STATE_IDLE, STATE_WRITE, STATE_CHECK, STATE_FINISH, STATE_ERROR, STATE_WAIT,
                   STATE_ABORT0, STATE_ABORT1);

  -----------------------------------------------------------------------------
  -- signals
  -----------------------------------------------------------------------------

  -- registers
  signal AddrxDP, AddrxDN       : unsigned(ADDR_WIDTH downto 0);
  signal StatexDP, StatexDN     : state_t;
  signal WaitxDP, WaitxDN       : unsigned(2 downto 0);
  signal ICAPCExSBP, ICAPCExSBN : std_logic;
  signal ICAPWExSBP, ICAPWExSBN : std_logic;

  -- ordinary signals
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
      StatexDP      <= STATE_IDLE;
      AddrxDP       <= unsigned(conv_std_logic_vector(0, AddrxDP'length));
      WaitxDP       <= unsigned(conv_std_logic_vector(0, WaitxDP'length));
      ICAPWExSBP <= '0';
      ICAPCExSBP <= '1';
    elsif ClkxCI'event and ClkxCI = '1' then  -- rising clock edge
      StatexDP      <= StatexDN;
      AddrxDP       <= AddrxDN;
      WaitxDP       <= WaitxDN;
      ICAPWExSBP <= ICAPWExSBN;
      ICAPCExSBP <= ICAPCExSBN;
    end if;
  end process regFF;

  -----------------------------------------------------------------------------
  -- ICAP FSM
  -----------------------------------------------------------------------------

  icapFSM : process (AddrxDN, AddrxDP, ICAPErrorxS, LenxDI, ModexSI, StartxSI,
                     StatexDP, WaitxDN, WaitxDP)
  begin  -- process icapFSM
    StatexDN   <= StatexDP;
    AddrxDN    <= AddrxDP;
    WaitxDN    <= WaitxDP;
    ICAPCExSBN <= '1';                  -- active low, so not active here
    ICAPWExSBN <= '0';                  -- active low, doing a write
    DonexS     <= '0';
    ErrorxS    <= '0';


    case StatexDP is
      -------------------------------------------------------------------------
      -- Abort, chip select and change from read to write
      -------------------------------------------------------------------------
      when STATE_ABORT0 =>
        ICAPCExSBN <= '0';
        ICAPWExSBN <= '1';

        StatexDN <= STATE_ABORT1;

        -------------------------------------------------------------------------
        -- Abort, chip select and read => causes an abort
        -------------------------------------------------------------------------
      when STATE_ABORT1 =>
        ICAPCExSBN <= '0';
        ICAPWExSBN <= '0';

        DonexS <= '1';

        WaitxDN  <= unsigned(conv_std_logic_vector(5, WaitxDN'length));
        StatexDN <= STATE_WAIT;

        -------------------------------------------------------------------------
        -- wait state, we wait for WaitxDN cycles before returning to STATE_IDLE
        -------------------------------------------------------------------------
      when STATE_WAIT =>
        WaitxDN <= WaitxDP - 1;

        if WaitxDN = unsigned(conv_std_logic_vector(0, WaitxDN'length)) then
          StatexDN <= STATE_IDLE;
        end if;

        -------------------------------------------------------------------------
        -- idle state, wait for start signal
        -------------------------------------------------------------------------
      when STATE_IDLE =>
        AddrxDN <= unsigned(conv_std_logic_vector(0, AddrxDP'length));

        if StartxSI = '1' then
          if ModexSI = '1' then
            StatexDN <= STATE_ABORT0;
          else
            StatexDN <= STATE_WRITE;
          end if;
        end if;

        -------------------------------------------------------------------------
        -- Write to ICAP
        -------------------------------------------------------------------------
      when STATE_WRITE =>
        ICAPCExSBN <= '0';              -- active low
        AddrxDN    <= AddrxDP + 1;

        if ICAPErrorxS = '1' then
          StatexDN <= STATE_ERROR;
        end if;

        if std_logic_vector(AddrxDN) = LenxDI then
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

        WaitxDN  <= unsigned(conv_std_logic_vector(1, WaitxDN'length));
        StatexDN <= STATE_WAIT;

        -----------------------------------------------------------------------
        -- An error occurred, set ErrorxS to high
        -----------------------------------------------------------------------
      when STATE_ERROR =>
        ErrorxS <= '1';

        WaitxDN  <= unsigned(conv_std_logic_vector(1, WaitxDN'length));
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
  ICAPErrorxS <= '0';                   -- TODO: replace not ICAPStatusxDI(24);
  ICAPCExSBO  <= ICAPCExSBP;
  ICAPWExSBO  <= ICAPWExSBP;

  -----------------------------------------------------------------------------
  -- output assignments
  -----------------------------------------------------------------------------
  ErrorxSO   <= ErrorxS;
  DonexSO    <= DonexS;
  RamAddrxDO <= std_logic_vector(AddrxDP(ADDR_WIDTH-1 downto 0));

end implementation;
