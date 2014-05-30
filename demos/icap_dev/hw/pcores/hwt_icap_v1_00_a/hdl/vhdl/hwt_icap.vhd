-------------------------------------------------------------------------------
-- Title      : HWT_ICAP
-- Project    : 
-------------------------------------------------------------------------------
-- File       : hwt_icap.vhd
-- Author     : atraber  <atraber@student.ethz.ch>
-- Company    : Computer Engineering and Networks Laboratory, ETH Zurich
-- Created    : 2014-05-23
-- Last update: 2014-05-27
-- Platform   : Xilinx ISIM (simulation), Xilinx (synthesis)
-- Standard   : VHDL'87
-------------------------------------------------------------------------------
-- Description: This is a hardware thread for the ICAP interface. It supports
-- three different modes: Writing to ICAP, Reading from ICAP, and asserting GSR for
-- one cycle.
--
-- All reads and writes from the ICAP interface need buffers that have an
-- address that is 32 bit aligned. Also the readback size must be a multiple of
-- 32 bit.
--
-- Writing to ICAP can be done as follows:
-- 1. Send a msg containing the address of the bitstream in memory to the hardware
--    thread
-- 2. Send a msg containing the size of the bitstream (in bytes) to the hardware
--    thread
-- 3. The hardware thread now writes the bitstream to the ICAP interface
-- 4. The hardware thread sends a finished or error message to the CPU.
--    If a CRC error was detected, the CRC register will be reset by the
--    hardware thread.
--
-- Reading from ICAP can be done as follows:
-- 1. Send a msg containg the address of the buffer used for readback to the
--    hardware thread
-- 2. Send a msg containing the amount of data (in bytes) you would like to
--    read from ICAP, perform a logical OR it with 0x00000001. This tells the
--    hardware thread that it should read instead of write.
--    WARNING: The ICAP interface uses 82 dummy words before the real data,
--    so if you would like to read 100 words from ICAP, you must actually read
--    182 reads and throw away the first 82 words.
--    WARNING2: If you read back more words than you told the ICAP interface
--    with the last command, this thread will hang and never finish. Make sure
--    that you always read exactly the amount you specified!
-- 3. The hardware thread now reads from the ICAP interface and moves the data
--    to memory
-- 4. The hardware thread sends a finished msg to the CPU
--
-- To perform GSR, you must do the following:
-- 1. Send a msg with the content 0x00000001 to the hardware thread.
-- 2. The hardware thread now asserts GSR for one cycle
-- 3. The hardware thread sends a finished msg to the CPU
-------------------------------------------------------------------------------
-- Copyright (c) 2014 Computer Engineering and Networks Laboratory, ETH Zurich
-------------------------------------------------------------------------------
-- Revisions  :
-- Date        Version  Author  Description
-- 2014-05-23  1.0      atraber	Created
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

library proc_common_v3_00_a;
use proc_common_v3_00_a.proc_common_pkg.all;

library reconos_v3_00_b;
use reconos_v3_00_b.reconos_pkg.all;

library unisim;
use unisim.vcomponents.STARTUP_VIRTEX6;


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
      AckxSI        : in  std_logic;
      DonexSO       : out std_logic;
      ErrorxSO      : out std_logic;
      LenxDI        : in  std_logic_vector(0 to ADDR_WIDTH);
      ModexSI       : in  std_logic;
      UpperxSI      : in  std_logic;
      RamAddrxDO    : out std_logic_vector(0 to ADDR_WIDTH-1);
      RamWExSo      : out std_logic;
      RamLutMuxxSO  : out std_logic;
      ICAPCExSBO    : out std_logic;
      ICAPWExSBO    : out std_logic;
      ICAPStatusxDI : in  std_logic_vector(0 to 7);
      ICAPBusyxSI   : in  std_logic
      );
  end component;

  component ICAPWrapper
    generic (
      ICAP_WIDTH : natural);
    port (
      clk   : in  std_logic;
      csb   : in  std_logic;
      rdwrb : in  std_logic;
      i     : in  std_logic_vector(0 to ICAP_WIDTH-1);
      busy  : out std_logic;
      o     : out std_logic_vector(0 to ICAP_WIDTH-1));
  end component;

  component CmdLut
    port (
      ClkxCI  : in  std_logic;
      AddrxDI : in  std_logic_vector(0 to 3);
      OutxDO  : out std_logic_vector(0 to 31));
  end component;

  -----------------------------------------------------------------------------
  -- signals
  -----------------------------------------------------------------------------
  type STATE_TYPE is (STATE_GET_BITSTREAM_ADDR, STATE_GET_BITSTREAM_SIZE, STATE_THREAD_EXIT,
                      STATE_FINISHED, STATE_ERROR, STATE_CMPLEN, STATE_FETCH_MEM,
                      STATE_ICAP_TRANSFER, STATE_ICAP_WAIT, STATE_ICAP_WAIT_LAST,
                      STATE_MEM_CALC, STATE_GSR,
                      STATE_READ_CMPLEN, STATE_READ_ICAP, STATE_PUT_MEM, STATE_READ_CALC);

  constant MBOX_RECV   : std_logic_vector(C_FSL_WIDTH-1 downto 0) := x"00000000";
  constant MBOX_SEND   : std_logic_vector(C_FSL_WIDTH-1 downto 0) := x"00000001";
  constant RESULT_OK   : std_logic_vector(31 downto 0)            := x"00001337";
  constant RESULT_FAIL : std_logic_vector(31 downto 0)            := x"00000666";
  constant ICAP_WIDTH  : integer                                  := 32;

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
  signal ICAPRamWExS   : std_logic;
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
  signal AddrxD            : std_logic_vector(31 downto 0);  -- in bytes
  signal LenxD             : std_logic_vector(31 downto 0);  -- in bytes
  signal LastxS            : std_logic;
  signal FirstxS           : std_logic;
  signal UpperxS           : std_logic;
  signal ICAPDataOutRegxDP : std_logic_vector(0 to ICAP_WIDTH-1);
  signal ICAPBusyRegxSP    : std_logic;

  -- icap signals
  signal ICAPBusyxS    : std_logic;
  signal ICAPCExSB     : std_logic;
  signal ICAPWExSB     : std_logic;
  signal ICAPDataOutxD : std_logic_vector(0 to ICAP_WIDTH-1);
  signal ICAPDataInxD  : std_logic_vector(0 to ICAP_WIDTH-1);

  signal ICAPLutOutxD : std_logic_vector(0 to ICAP_WIDTH-1);

  signal ICAPFsmStartxS  : std_logic;
  signal ICAPFsmAckxS    : std_logic;
  signal ICAPFsmModexS   : std_logic;
  signal ICAPRamLutMuxxS : std_logic;
  signal ICAPFsmDonexS   : std_logic;
  signal ICAPFsmErrorxS  : std_logic;
  signal ICAPFsmLenxD    : std_logic_vector(0 to C_LOCAL_RAM_ADDRESS_WIDTH);  -- in words


  signal GSRxS : std_logic := '0';

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
      if (ICAPRamWExS = '1') then
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
  reconos_fsm : process (clk, rst, o_osif, o_memif, o_ram) is
    variable done      : boolean;
    variable localAddr : std_logic_vector(31 downto 0);
    variable len       : std_logic_vector(23 downto 0);
  begin
    if rst = '1' then
      osif_reset(o_osif);
      memif_reset(o_memif);
      ram_reset(o_ram);
      state <= STATE_GET_BITSTREAM_ADDR;
      done  := false;

      AddrxD  <= (others => '0');
      LenxD   <= (others => '0');
      LastxS  <= '0';
      FirstxS <= '0';
      UpperxS <= '0';
    elsif rising_edge(clk) then

      -- default assignments
      ICAPFsmLenxD   <= conv_std_logic_vector(C_LOCAL_RAM_SIZE/2, C_LOCAL_RAM_ADDRESS_WIDTH + 1);
      ICAPFsmStartxS <= '0';
      ICAPFsmAckxS   <= '0';
      ICAPFsmModexS  <= '0';            -- write
      GSRxS          <= '0';

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
              if AddrxD(0) = '1' then
                AddrxD(0) <= '0';
                state     <= STATE_GSR;
              else
                state <= STATE_GET_BITSTREAM_SIZE;
              end if;
            end if;
          end if;

          ---------------------------------------------------------------------
          -- get bitstream len
          ---------------------------------------------------------------------
        when STATE_GET_BITSTREAM_SIZE =>
          osif_mbox_get(i_osif, o_osif, MBOX_RECV, LenxD, done);

          FirstxS <= '1';
          UpperxS <= '0';

          if done then
            if (LenxD = X"FFFFFFFF") then
              state <= STATE_THREAD_EXIT;
            else
              if LenxD(0) = '1' then
                LenxD(0) <= '0';
                state    <= STATE_READ_CMPLEN;
              else
                state <= STATE_CMPLEN;
              end if;
            end if;
          end if;

          ---------------------------------------------------------------------
          -- GSR
          ---------------------------------------------------------------------
        when STATE_GSR =>
          GSRxS <= '1';

          state <= STATE_FINISHED;

          ---------------------------------------------------------------------
          -- Compare the remaining length of the bitstream with the size of our
          -- memory
          ---------------------------------------------------------------------
        when STATE_CMPLEN =>
          if LenxD <= (C_LOCAL_RAM_SIZE_IN_BYTES/2) then
            LastxS <= '1';
          else
            LastxS <= '0';
          end if;

          state <= STATE_FETCH_MEM;

          ---------------------------------------------------------------------
          -- Copy data from main memory to our local memory
          ---------------------------------------------------------------------
        when STATE_FETCH_MEM =>
          if UpperxS = '1' then
            -- fill upper part of memory
            localAddr := conv_std_logic_vector(C_LOCAL_RAM_SIZE/2, 32);
          else
            -- fill lower part of memory
            localAddr := X"00000000";
          end if;

          if LastxS = '1' then
            -- LenxD is smaller than the size of half the local memory, so we
            -- only fill it partially
            len := LenxD(23 downto 0);
          else
            -- completely fill our half local memory
            len := conv_std_logic_vector(C_LOCAL_RAM_SIZE_IN_BYTES/2, 24);
          end if;

          memif_read(i_ram, o_ram, i_memif, o_memif, AddrxD, localAddr, len, done);

          if done then
            if FirstxS = '1' then
              state <= STATE_ICAP_TRANSFER;
            else
              state <= STATE_ICAP_WAIT;
            end if;
          end if;

          ---------------------------------------------------------------------
          -- Wait for running ICAP before proceeding to next transfer
          ---------------------------------------------------------------------
        when STATE_ICAP_WAIT =>
          ICAPFsmAckxS <= '1';

          if ICAPFsmErrorxS = '1' then
            state <= STATE_ERROR;
          end if;

          if ICAPFsmDonexS = '1' then
            state <= STATE_ICAP_TRANSFER;
          end if;

          ---------------------------------------------------------------------
          -- Wait for running ICAP before proceeding to finish
          ---------------------------------------------------------------------
        when STATE_ICAP_WAIT_LAST =>
          ICAPFsmAckxS <= '1';

          if ICAPFsmErrorxS = '1' then
            state <= STATE_ERROR;
          end if;

          if ICAPFsmDonexS = '1' then
            state <= STATE_FINISHED;
          end if;

          ---------------------------------------------------------------------
          -- Send the data in our local memory to the ICAP port
          ---------------------------------------------------------------------
        when STATE_ICAP_TRANSFER =>
          ICAPFsmStartxS <= '1';

          if LastxS = '1' then
            -- the remaining size is less than half of our local memory size
            -- convert length from bytes to words here
            ICAPFsmLenxD <= LenxD(C_LOCAL_RAM_ADDRESS_WIDTH + 2 downto 2);

            state <= STATE_ICAP_WAIT_LAST;
          else
            -- transfer the content of the full memory to ICAP
            ICAPFsmLenxD <= conv_std_logic_vector(C_LOCAL_RAM_SIZE/2, C_LOCAL_RAM_ADDRESS_WIDTH + 1);

            state <= STATE_MEM_CALC;
          end if;

          ---------------------------------------------------------------------
          -- Calculate the remaining length of the bitfile and the new address
          ---------------------------------------------------------------------
        when STATE_MEM_CALC =>
          AddrxD <= AddrxD + (C_LOCAL_RAM_SIZE_IN_BYTES/2);
          LenxD  <= LenxD - (C_LOCAL_RAM_SIZE_IN_BYTES/2);

          UpperxS <= not UpperxS;
          FirstxS <= '0';

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
          -- We are finished, send a message
          ---------------------------------------------------------------------
        when STATE_FINISHED =>
          osif_mbox_put(i_osif, o_osif, MBOX_SEND, RESULT_OK, ignore, done);

          if done then
            state <= STATE_GET_BITSTREAM_ADDR;
          end if;

          ---------------------------------------------------------------------
          -- Compare given length with the size of our local ram
          -- If the length if smaller than the size of half of our ram, we are in
          -- the final run and can give the actual remaining size as an argument
          -- the icap fsm, otherwise we specify the size of half of our ram
          ---------------------------------------------------------------------
        when STATE_READ_CMPLEN =>
          if LenxD <= C_LOCAL_RAM_SIZE_IN_BYTES then
            LastxS <= '1';
          else
            LastxS <= '0';
          end if;

          state <= STATE_READ_ICAP;

          ---------------------------------------------------------------------
          -- Read from ICAP interface
          -- TODO: this should also be double buffered!
          ---------------------------------------------------------------------
        when STATE_READ_ICAP =>
          ICAPFsmModexS  <= '1';        -- read
          ICAPFsmStartxS <= '1';
          UpperxS        <= '0';

          if LastxS = '1' then
            -- convert the remaining size from bytes to words
            ICAPFsmLenxD <= LenxD(C_LOCAL_RAM_ADDRESS_WIDTH + 2 downto 2);
          else
            ICAPFsmLenxD <= conv_std_logic_vector(C_LOCAL_RAM_SIZE, C_LOCAL_RAM_ADDRESS_WIDTH + 1);
          end if;

          if ICAPFsmDonexS = '1' then
            -- we ack it already in this state as we do not need this signal when
            -- we are not doing double buffering
            ICAPFsmAckxS <= '1';

            state <= STATE_PUT_MEM;
          end if;

          ---------------------------------------------------------------------
          -- Copy the content of the local RAM to the main memory
          ---------------------------------------------------------------------
        when STATE_PUT_MEM =>
          if LastxS = '1' then
            -- LenxD is smaller than the size of our local memory, so we
            -- only copy it partially
            len := LenxD(23 downto 0);
          else
            -- completely copy our local memory to main memory
            len := conv_std_logic_vector(C_LOCAL_RAM_SIZE_IN_BYTES, 24);
          end if;

          memif_write(i_ram, o_ram, i_memif, o_memif, X"00000000", AddrxD,
                      len, done);

          if Done then
            if LastxS = '1' then
              state <= STATE_FINISHED;
            else
              state <= STATE_READ_CALC;
            end if;
          end if;

          ---------------------------------------------------------------------
          -- Calculate the remaining length that we still have to fetch from
          -- ICAP and the corresponding address in main memory
          ---------------------------------------------------------------------
        when STATE_READ_CALC =>
          AddrxD <= AddrxD + C_LOCAL_RAM_SIZE_IN_BYTES;
          LenxD  <= LenxD - C_LOCAL_RAM_SIZE_IN_BYTES;

          state <= STATE_READ_CMPLEN;

          ---------------------------------------------------------------------
          -- thread exit
          ---------------------------------------------------------------------
        when STATE_THREAD_EXIT =>
          osif_thread_exit(i_osif, o_osif);
      end case;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- ICAP wrapper, the wrapper just passes through the signals
  -- It mainly exists to make simulation easier as we can just replace the
  -- wrapper for simulation runs
  -----------------------------------------------------------------------------
  icapWrapperInst : ICAPWrapper
    generic map (
      ICAP_WIDTH => ICAP_WIDTH
      )
    port map (
      clk   => clk,
      csb   => ICAPCExSB,               -- active low
      rdwrb => ICAPWExSB,               -- active low
      i     => ICAPDataInxD,
      busy  => ICAPBusyxS,
      o     => ICAPDataOutxD);

  -----------------------------------------------------------------------------
  -- STARTUP_VIRTEX6 interface, the grestore command does not work, so we need
  -- to toggle the GSR signal manually
  -----------------------------------------------------------------------------
  STARTUP_VIRTEX6Inst : STARTUP_VIRTEX6
    generic map (
      PROG_USR => false  -- Activate program event security feature
      )
    port map (
      CFGCLK    => open,  -- 1-bit output Configuration main clock output
      CFGMCLK   => open,  -- 1-bit output Configuration internal oscillator clock output
      DINSPI    => open,  -- 1-bit output DIN SPI PROM access output
      EOS       => open,  -- 1-bit output Active high output signal indicating the End Of Configuration.
      PREQ      => open,  -- 1-bit output PROGRAM request to fabric output
      TCKSPI    => open,  -- 1-bit output TCK configuration pin access output
      CLK       => '0',  -- 1-bit input User start-up clock input
      GSR       => GSRxS,  -- 1-bit input Global Set/Reset input (GSR cannot be used for the port name)
      GTS       => '0',  -- 1-bit input Global 3-state input (GTS cannot be used for the port name)
      KEYCLEARB => '0',  -- 1-bit input Clear AES Decrypter Key input from Battery-Backed RAM (BBRAM)
      PACK      => '0',  -- 1-bit input PROGRAM acknowledge input
      USRCCLKO  => '0',                 -- 1-bit input User CCLK input
      USRCCLKTS => '0',  -- 1-bit input User CCLK 3-state enable input
      USRDONEO  => '1',  -- 1-bit input User DONE pin output control
      USRDONETS => '1'   -- 1-bit input User DONE 3-state enable output
      );

  -----------------------------------------------------------------------------
  -- ICAP Registers
  -----------------------------------------------------------------------------
  icapFF : process (clk)
  begin  -- process icapFF
    if clk'event and clk = '1' then     -- rising clock edge
      ICAPDataOutRegxDP <= ICAPDataOutxD;
      ICAPBusyRegxSP    <= ICAPBusyxS;
    end if;
  end process icapFF;

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
      AckxSI        => ICAPFsmAckxS,
      DonexSO       => ICAPFsmDonexS,
      ErrorxSO      => ICAPFsmErrorxS,
      LenxDI        => ICAPFsmLenxD,
      ModexSI       => ICAPFsmModexS,
      UpperxSI      => UpperxS,
      RamAddrxDO    => ICAPRamAddrxD,
      RamWExSO      => ICAPRamWExS,
      RamLutMuxxSO  => ICAPRamLutMuxxS,
      ICAPCExSBO    => ICAPCExSB,
      ICAPWExSBO    => ICAPWExSB,
      ICAPStatusxDI => ICAPDataOutxD(24 to 31),
      ICAPBusyxSI   => ICAPBusyRegxSP
      );

  -----------------------------------------------------------------------------
  -- ICAP Command Lookup-Table
  -----------------------------------------------------------------------------
  cmdLutInst : CmdLut
    port map (
      ClkxCI  => clk,
      AddrxDI => ICAPRamAddrxD(ICAPRamAddrxD'length-4 to ICAPRamAddrxD'length-1),
      OutxDO  => ICAPLutOutxD);

  -----------------------------------------------------------------------------
  -- concurrent signal assignments
  -----------------------------------------------------------------------------

  ICAPDataInxD <= ICAPRamOutxD when ICAPRamLutMuxxS = '0'
                  else ICAPLutOutxD;

  -- ICAP Ram Input
  ICAPRamInxD <= ICAPDataOutRegxDP;

end architecture;

