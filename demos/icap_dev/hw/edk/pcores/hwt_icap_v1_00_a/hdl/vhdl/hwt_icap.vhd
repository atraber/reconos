library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

library proc_common_v3_00_a;
use proc_common_v3_00_a.proc_common_pkg.all;

library reconos_v3_00_b;
use reconos_v3_00_b.reconos_pkg.all;

library unisim;
use unisim.vcomponents.all;

entity hwt_icap is
  port (
    -- OSIF FSL   
    OSFSL_S_Read    : out std_logic;  -- Read signal, requiring next available input to be read
    OSFSL_S_Data    : in  std_logic_vector(0 to 31);  -- Input data
    OSFSL_S_Control : in  std_logic;  -- Control Bit, indicating the input data are control word
    OSFSL_S_Exists  : in  std_logic;  -- Data Exist Bit, indicating data exist in the input FSL bus

    OSFSL_M_Write   : out std_logic;  -- Write signal, enabling writing to output FSL bus
    OSFSL_M_Data    : out std_logic_vector(0 to 31);  -- Output data
    OSFSL_M_Control : out std_logic;  -- Control Bit, indicating the output data are contol word
    OSFSL_M_Full    : in  std_logic;  -- Full Bit, indicating output FSL bus is full

    -- FIFO Interface
    FIFO32_S_Data : in  std_logic_vector(31 downto 0);
    FIFO32_M_Data : out std_logic_vector(31 downto 0);
    FIFO32_S_Fill : in  std_logic_vector(15 downto 0);
    FIFO32_M_Rem  : in  std_logic_vector(15 downto 0);
    FIFO32_S_Rd   : out std_logic;
    FIFO32_M_Wr   : out std_logic;


    -- DEBUG
    DebugICAPFsmStart      : out std_logic;
    DebugICAPFsmDone       : out std_logic;
    DebugICAPFsmError      : out std_logic;
    DebugICAPRamAddr       : out std_logic_vector(0 to 10);
    DebugICAPFsmLen        : out std_logic_vector(0 to 10);
    DebugLen               : out std_logic_vector(31 downto 0);
    DebugAddr              : out std_logic_vector(31 downto 0);
    DebugStateIsGetLength  : out std_logic;
    DebugStateMemCalc      : out std_logic;
    DebugStateIcapTransfer : out std_logic;
    DebugICAPDataIn        : out std_logic_vector(0 to 31);
    DebugICAPOut           : out std_logic_vector(0 to 31);
    DebugICAPStatusError   : out std_logic;
    DebugICAPCE            : out std_logic;
    DebugICAPWE            : out std_logic;
    DebugICAPBusy          : out std_logic;
    DebugICAPRamOut        : out std_logic_vector(0 to 31);

    -- HWT reset and clock
    clk : in std_logic;
    rst : in std_logic
    );
end entity;

architecture implementation of hwt_icap is
  -----------------------------------------------------------------------------
  -- components
  -----------------------------------------------------------------------------
  component ICAPFsm
    generic (
      ADDR_WIDTH : natural);
    port (
      ClkxCI        : in  std_logic;
      ResetxRI      : in  std_logic;
      StartxSI      : in  std_logic;
      ModexSI       : in  std_logic;
      DonexSO       : out std_logic;
      ErrorxSO      : out std_logic;
      LenxDI        : in  std_logic_vector(0 to ADDR_WIDTH-1);
      RamAddrxDO    : out std_logic_vector(0 to ADDR_WIDTH-1);
      ICAPCExSBO    : out std_logic;
      ICAPWExSBO    : out std_logic;
      ICAPStatusxDI : in  std_logic_vector(0 to 31));
  end component;

  -----------------------------------------------------------------------------
  -- signals
  -----------------------------------------------------------------------------
  type STATE_TYPE is (STATE_GET_BITSTREAM_ADDR, STATE_GET_BITSTREAM_SIZE, STATE_THREAD_EXIT,
                      STATE_FINISHED, STATE_ERROR, STATE_CMPLEN, STATE_FETCH_MEM,
                      STATE_ICAP_TRANSFER, STATE_ICAP_ABORT, STATE_MEM_CALC);

  constant MBOX_RECV   : std_logic_vector(C_FSL_WIDTH-1 downto 0) := x"00000000";
  constant MBOX_SEND   : std_logic_vector(C_FSL_WIDTH-1 downto 0) := x"00000001";
  constant RESULT_OK   : std_logic_vector(31 downto 0)            := x"13371337";
  constant RESULT_FAIL : std_logic_vector(31 downto 0)            := x"FA17FA17";
  constant ICAP_DWIDTH : integer                                  := 32;
  constant ICAP_WIDTH  : string                                   := "X32";

  constant C_LOCAL_RAM_SIZE          : integer := 2048;  -- in words
  constant C_LOCAL_RAM_ADDRESS_WIDTH : integer := clog2(C_LOCAL_RAM_SIZE);
  constant C_LOCAL_RAM_SIZE_IN_BYTES : integer := 4*C_LOCAL_RAM_SIZE;

  type LOCAL_MEMORY_T is array (0 to C_LOCAL_RAM_SIZE-1) of std_logic_vector(31 downto 0);

  signal state   : STATE_TYPE;
  signal i_osif  : i_osif_t;
  signal o_osif  : o_osif_t;
  signal i_memif : i_memif_t;
  signal o_memif : o_memif_t;
  signal i_ram   : i_ram_t;
  signal o_ram   : o_ram_t;

  -- local FSM RAM signals
  signal ICAPRamAddrxD : std_logic_vector(0 to C_LOCAL_RAM_ADDRESS_WIDTH-1);  -- in words
  signal ICAPRamOutxD  : std_logic_vector(0 to 31);
  signal ICAPRamWExD   : std_logic;
  signal ICAPRamInxD   : std_logic_vector(0 to 31);

  -- reconos RAM signals
  signal o_RAMAddr_reconos   : std_logic_vector(0 to C_LOCAL_RAM_ADDRESS_WIDTH-1);
  signal o_RAMAddr_reconos_2 : std_logic_vector(0 to 31);
  signal o_RAMData_reconos   : std_logic_vector(0 to 31);
  signal o_RAMWE_reconos     : std_logic;
  signal i_RAMData_reconos   : std_logic_vector(0 to 31);

  constant o_RAMAddr_max : std_logic_vector(0 to C_LOCAL_RAM_ADDRESS_WIDTH-1) := (others => '1');

  shared variable local_ram : LOCAL_MEMORY_T;

  signal ignore : std_logic_vector(C_FSL_WIDTH-1 downto 0);

  -- registers
  signal AddrxD : std_logic_vector(31 downto 0);  -- in bytes
  signal LenxD  : std_logic_vector(31 downto 0);  -- in bytes
  signal LastxD : std_logic;

  -- helper signals
  signal LenSwapxD : std_logic_vector(0 to 31);

  -- icap signals
  signal ICAPBusyxS    : std_logic;
  signal ICAPCExSB     : std_logic;
  signal ICAPWExSB     : std_logic;
  signal ICAPDataInxD  : std_logic_vector(0 to ICAP_DWIDTH-1);
  signal ICAPDataOutxD : std_logic_vector(0 to ICAP_DWIDTH-1);

  signal ICAPFsmStartxS : std_logic;
  signal ICAPFsmModexS  : std_logic;
  signal ICAPFsmDonexS  : std_logic;
  signal ICAPFsmErrorxS : std_logic;
  signal ICAPFsmLenxD   : std_logic_vector(0 to C_LOCAL_RAM_ADDRESS_WIDTH-1);  -- in words

begin

  -- setup osif, memif, local ram
  fsl_setup(i_osif, o_osif, OSFSL_S_Data, OSFSL_S_Exists, OSFSL_M_Full, OSFSL_M_Data, OSFSL_S_Read, OSFSL_M_Write, OSFSL_M_Control);
  memif_setup(i_memif, o_memif, FIFO32_S_Data, FIFO32_S_Fill, FIFO32_S_Rd, FIFO32_M_Data, FIFO32_M_Rem, FIFO32_M_Wr);
  ram_setup(i_ram, o_ram, o_RAMAddr_reconos_2, o_RAMData_reconos, i_RAMData_reconos, o_RAMWE_reconos);

  -----------------------------------------------------------------------------
  -- local dual-port ram
  -----------------------------------------------------------------------------

  -- reconos port
  local_ram_ctrl_1 : process (clk) is
  begin
    if (rising_edge(clk)) then
      if (o_RAMWE_reconos = '1') then
        local_ram(conv_integer(unsigned(o_RAMAddr_reconos))) := o_RAMData_reconos;
      else
        i_RAMData_reconos <= local_ram(conv_integer(unsigned(o_RAMAddr_reconos)));
      end if;
    end if;
  end process;

  o_RAMAddr_reconos(0 to C_LOCAL_RAM_ADDRESS_WIDTH-1) <= o_RAMAddr_reconos_2((32-C_LOCAL_RAM_ADDRESS_WIDTH) to 31);

  -- local FSM port
  local_ram_ctrl_2 : process (clk) is
  begin
    if (rising_edge(clk)) then
      if (ICAPRamWExD = '1') then
        local_ram(conv_integer(unsigned(ICAPRamAddrxD))) := ICAPRamInxD;
      else
        ICAPRamOutxD <= local_ram(conv_integer(unsigned(ICAPRamAddrxD)));
      end if;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- Reconos FSM
  -- os and memory synchronisation state machine
  -----------------------------------------------------------------------------
  reconos_fsm : process (clk, rst, o_osif) is
    variable done : boolean;
  begin
    if rst = '1' then
      osif_reset(o_osif);
      memif_reset(o_memif);
      ram_reset(o_ram);
      state <= STATE_GET_BITSTREAM_ADDR;
      done  := false;

      AddrxD <= (others => '0');
      LenxD  <= (others => '0');
      LastxD <= '0';
    elsif rising_edge(clk) then

      -- default assignments
      ICAPFsmLenxD   <= (others => '1');
      ICAPFsmStartxS <= '0';
      ICAPFsmModexS  <= '0';            -- write

      case state is
        -----------------------------------------------------------------------
        -- get mem address
        -----------------------------------------------------------------------
        when STATE_GET_BITSTREAM_ADDR =>
          osif_mbox_get(i_osif, o_osif, MBOX_RECV, AddrxD, done);

          if done then
            if (AddrxD = X"FFFFFFFF") then
              state <= STATE_THREAD_EXIT;
            else
              state <= STATE_GET_BITSTREAM_SIZE;
            end if;
          end if;

          ---------------------------------------------------------------------
          -- get bitstream len
          ---------------------------------------------------------------------
        when STATE_GET_BITSTREAM_SIZE =>
          osif_mbox_get(i_osif, o_osif, MBOX_RECV, LenxD, done);

          if done then
            if (LenxD = X"FFFFFFFF") then
              state <= STATE_THREAD_EXIT;
            else
              state <= STATE_ICAP_ABORT;
            end if;
          end if;

          ---------------------------------------------------------------------
          -- Do an ICAP abort to ensure that we are using the active ICAP interface
          ---------------------------------------------------------------------
        when STATE_ICAP_ABORT =>
          ICAPFsmStartxS <= '1';
          ICAPFsmModexS  <= '1';        -- abort

          if ICAPFsmDonexS = '1' then
            state <= STATE_CMPLEN;
          end if;

          ---------------------------------------------------------------------
          -- Compare the remaining length of the bitstream with the size of our
          -- memory
          ---------------------------------------------------------------------
        when STATE_CMPLEN =>
          if LenxD <= C_LOCAL_RAM_SIZE_IN_BYTES then
            LastxD <= '1';
          else
            LastxD <= '0';
          end if;

          state <= STATE_FETCH_MEM;

          ---------------------------------------------------------------------
          -- Copy data from main memory to our local memory
          ---------------------------------------------------------------------
        when STATE_FETCH_MEM =>
          if LastxD = '1' then
            -- LenxD is smaller than the size of local memory, so we only fill
            -- it partially
            memif_read(i_ram, o_ram, i_memif, o_memif, AddrxD, X"00000000",
                       LenxD(23 downto 0), done);
          else
            -- completely fill our local memory
            memif_read(i_ram, o_ram, i_memif, o_memif, AddrxD, X"00000000",
                       conv_std_logic_vector(C_LOCAL_RAM_SIZE_IN_BYTES, 24), done);
          end if;

          if done then
            state <= STATE_ICAP_TRANSFER;
          end if;

          ---------------------------------------------------------------------
          -- Send the data in our local memory to the ICAP port
          ---------------------------------------------------------------------
        when STATE_ICAP_TRANSFER =>
          ICAPFsmStartxS <= '1';

          if LastxD = '1' then
            -- the remaining size is less than our local memory size
            -- convert length from bytes to words here
            ICAPFsmLenxD <= LenxD(C_LOCAL_RAM_ADDRESS_WIDTH-1+2 downto 2);
          else
            -- transfer the content of the full memory to ICAP
            ICAPFsmLenxD <= (others => '1');
          end if;

          if ICAPFsmErrorxS = '1' then
            state <= STATE_ERROR;
          else
            if ICAPFsmDonexS = '1' then
              if LastxD = '1' then
                state <= STATE_FINISHED;
              else
                state <= STATE_MEM_CALC;
              end if;
            end if;
          end if;

          ---------------------------------------------------------------------
          -- Calculate the remaining length of the bitfile and the new address
          ---------------------------------------------------------------------
        when STATE_MEM_CALC =>
          AddrxD <= AddrxD + C_LOCAL_RAM_SIZE_IN_BYTES;
          LenxD  <= LenxD - C_LOCAL_RAM_SIZE_IN_BYTES;

          state <= STATE_CMPLEN;

          ---------------------------------------------------------------------
          -- Oops, an error occurred! Tell the software that we are in trouble
          ---------------------------------------------------------------------
        when STATE_ERROR =>
          osif_mbox_put(i_osif, o_osif, MBOX_SEND, RESULT_FAIL, ignore, done);

          if done then
            state <= STATE_GET_BITSTREAM_ADDR;
          end if;

          ---------------------------------------------------------------------
          -- We are finished, send message
          ---------------------------------------------------------------------
        when STATE_FINISHED =>
          osif_mbox_put(i_osif, o_osif, MBOX_SEND, RESULT_OK, ignore, done);

          if done then
            state <= STATE_GET_BITSTREAM_ADDR;
          end if;

          ---------------------------------------------------------------------
          -- thread exit
          ---------------------------------------------------------------------
        when STATE_THREAD_EXIT =>
          osif_thread_exit(i_osif, o_osif);
      end case;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- ICAP primitive of virtex 6
  -----------------------------------------------------------------------------
  ICAP_VERTEX6_I : ICAP_VIRTEX6
    generic map (
      ICAP_WIDTH => ICAP_WIDTH)
    port map (
      clk   => clk,
      csb   => ICAPCExSB,               -- active low
      rdwrb => ICAPWExSB,               -- active low
      i     => ICAPDataInxD,
      busy  => ICAPBusyxS,
      o     => ICAPDataOutxD);


  -----------------------------------------------------------------------------
  -- ICAPFsm
  -----------------------------------------------------------------------------
  ICAPFsmInst : ICAPFsm
    generic map (
      ADDR_WIDTH => C_LOCAL_RAM_ADDRESS_WIDTH)
    port map (
      ClkxCI        => clk,
      ResetxRI      => rst,
      StartxSI      => ICAPFsmStartxS,
      ModexSI       => ICAPFsmModexS,
      DonexSO       => ICAPFsmDonexS,
      ErrorxSO      => ICAPFsmErrorxS,
      LenxDI        => ICAPFsmLenxD,
      RamAddrxDO    => ICAPRamAddrxD,
      ICAPCExSBO    => ICAPCExSB,
      ICAPWExSBO    => ICAPWExSB,
      ICAPStatusxDI => ICAPDataOutxD);


  -----------------------------------------------------------------------------
  -- concurrent signal assignments
  -----------------------------------------------------------------------------

  ICAPRamInxD <= (others => '0');
  ICAPRamWExD <= '0';

  -- swap bit order
  LenSwapxD(0 to 31) <= LenxD(31 downto 0);

  -- bit swapping of RAM output so that it matches the input format of the ICAP
  -- interface, see pg 43 of UG360 (v3.7)
  -- TODO: check if this is correct!
  swapGen : for i in 0 to 3 generate
    bitSwapGen : for j in 0 to 7 generate
      ICAPDataInxD(i * 8 + j) <= ICAPRamOutxD((i + 1) * 8 - 1 - j);
    end generate bitSwapGen;
  end generate swapGen;


  -- DEBUG
  DebugICAPDataIn       <= ICAPDataInxD;
  DebugICAPRamOut       <= ICAPRamOutxD;
  DebugICAPOut          <= ICAPDataOutxD;
  DebugICAPStatusError  <= ICAPDataOutxD(25);
  DebugICAPCE           <= ICAPCExSB;
  DebugICAPWE           <= ICAPWExSB;
  DebugICAPBusy         <= ICAPBusyxS;
  DebugICAPFsmStart     <= ICAPFsmStartxS;
  DebugICAPFsmDone      <= ICAPFsmDonexS;
  DebugICAPFsmError     <= ICAPFsmErrorxS;
  DebugICAPFsmLen       <= ICAPFsmLenxD;
  DebugICAPRamAddr      <= ICAPRamAddrxD;
  DebugLen              <= LenxD;
  DebugAddr             <= AddrxD;
  DebugStateIsGetLength <= '1' when state = STATE_GET_BITSTREAM_SIZE
                           else '0';
  DebugStateMemCalc <= '1' when state = STATE_MEM_CALC
                       else '0';
  DebugStateIcapTransfer <= '1' when state = STATE_ICAP_TRANSFER
                            else '0';

end architecture;

