library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

library proc_common_v3_00_a;
use proc_common_v3_00_a.proc_common_pkg.all;

library reconos_v3_00_b;
use reconos_v3_00_b.reconos_pkg.all;

entity hwt_pr_app is
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

architecture implementation of hwt_pr_app is
  type STATE_TYPE is (STATE_GET_VALS, STATE_WRITE, STATE_READ, STATE_THREAD_EXIT,
                      STATE_MEM_READ, STATE_MEM_WRITE, STATE_START_MUL, STATE_FINISHED);

  constant MBOX_RECV : std_logic_vector(C_FSL_WIDTH-1 downto 0) := x"00000000";
  constant MBOX_SEND : std_logic_vector(C_FSL_WIDTH-1 downto 0) := x"00000001";

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

  -- reconos RAM signals
  signal o_RAMAddr_reconos   : std_logic_vector(0 to C_LOCAL_RAM_ADDRESS_WIDTH-1);
  signal o_RAMAddr_reconos_2 : std_logic_vector(0 to 31);
  signal o_RAMData_reconos   : std_logic_vector(0 to 31);
  signal o_RAMWE_reconos     : std_logic;
  signal i_RAMData_reconos   : std_logic_vector(0 to 31);

  constant o_RAMAddr_max : std_logic_vector(0 to C_LOCAL_RAM_ADDRESS_WIDTH-1) := (others => '1');

  shared variable local_ram : LOCAL_MEMORY_T := (others => x"FFFFFFFF");

  signal ignore : std_logic_vector(C_FSL_WIDTH-1 downto 0);

  signal vals : std_logic_vector(31 downto 0);
  signal msg  : std_logic_vector(31 downto 0);



  -- multiplier
  type   mul_state_t is (MUL_IDLE, MUL_START, MUL_WORK);
  signal AccxDP, AccxDN           : unsigned(31 downto 0);
  signal OpAxDP, OpAxDN           : unsigned(31 downto 0);
  signal OpBxDP, OpBxDN           : unsigned(31 downto 0);
  signal AccClearxS               : std_logic;
  signal MulRunningxS             : std_logic;
  signal MulStartxS               : std_logic;
  signal MulStatexDP, MulStatexDN : mul_state_t := MUL_IDLE;

  -----------------------------------------------------------------------------
  -- registers
  -----------------------------------------------------------------------------
  type   reg_t is array (0 to 3) of std_logic_vector(31 downto 0);
  signal RegistersxD : reg_t := (x"00000000", x"00000000", x"00000000", x"00000000");
begin

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
  -- local_ram_ctrl_2 : process (clk) is
  --  begin
  --    if (rising_edge(clk)) then
  --      if (ICAPRamWExS = '1') then
  --        local_ram(conv_integer(unsigned(ICAPRamAddrxD))) := ICAPRamInxD;
  --      else
  --        ICAPRamOutxD <= local_ram(conv_integer(unsigned(ICAPRamAddrxD)));
  --      end if;
  --    end if;
  --  end process;

  -----------------------------------------------------------------------------
  -- Very simple multiplier that uses only counters
  -----------------------------------------------------------------------------

  ---------------------------------------------------------------------------
  -- Registers
  ---------------------------------------------------------------------------
  mulFF : process (clk, rst)
  begin  -- process mulFF
    if rst = '1' then
      AccxDP      <= (others => '0');
      OpAxDP      <= (others => '0');
      OpBxDP      <= (others => '0');
      MulStatexDP <= MUL_IDLE;
    elsif clk'event and clk = '1' then  -- rising clock edge
      AccxDP      <= AccxDN;
      OpAxDP      <= OpAxDN;
      OpBxDP      <= OpBxDN;
      MulStatexDP <= MulStatexDN;
    end if;
  end process mulFF;


  ---------------------------------------------------------------------------
  -- FSM
  ---------------------------------------------------------------------------
  mulFsmComb : process (MulStartxS, MulStatexDP, OpAxDN, OpAxDP)
  begin  -- process mulFsmComb
    MulStatexDN  <= MulStatexDP;
    MulRunningxS <= '0';
    AccClearxS   <= '0';

    case MulStatexDP is
      -----------------------------------------------------------------------
      when MUL_IDLE =>
        if MulStartxS = '1' then
          MulStatexDN <= MUL_START;
        end if;

        ---------------------------------------------------------------------
      when MUL_START =>
        if OpAxDP = conv_unsigned(0, OpAxDP'length) then
          MulStatexDN <= MUL_IDLE;
        else
          MulStatexDN <= MUL_WORK;
        end if;

        AccClearxS <= '1';

        ---------------------------------------------------------------------
      when MUL_WORK =>
        if OpAxDN = conv_unsigned(0, OpAxDN'length) then
          MulStatexDN <= MUL_IDLE;
        end if;

        MulRunningxS <= '1';

        ---------------------------------------------------------------------
      when others => null;
    end case;
  end process mulFsmComb;

  ---------------------------------------------------------------------------
  -- concurrent signal assignments
  ---------------------------------------------------------------------------
  accComb : process (AccClearxS, AccxDP, MulRunningxS, OpBxDP)
  begin  -- process accComb
    if AccClearxS = '1' then
      AccxDN <= conv_unsigned(0, AccxDN'length);
    elsif MulRunningxS = '1' then
      AccxDN <= AccxDP + OpBxDP;
    else
      AccxDN <= AccxDP;
    end if;
  end process accComb;

  opAComb : process(MulRunningxS, MulStartxS, OpAxDP, RegistersxD)
  begin  -- process opAComb
    if MulStartxS = '1' then
      OpAxDN <= unsigned(RegistersxD(0));
    elsif MulRunningxS = '1' then
      OpAxDN <= OpAxDP - 1;
    else
      OpAxDN <= OpAxDP;
    end if;
  end process opAComb;

  OpBxDN <= unsigned(RegistersxD(1)) when MulStartxS = '1'
            else OpBxDP;

  -- os and memory synchronisation state machine
  reconos_fsm : process (clk, rst, o_osif) is
    variable done : boolean;
  begin
    if rst = '1' then
      vals  <= (others => '0');
      osif_reset(o_osif);
      memif_reset(o_memif);
      ram_reset(o_ram);
      state <= STATE_GET_VALS;
      done  := false;
    elsif rising_edge(clk) then

      -- default assignment
      RegistersxD(2) <= conv_std_logic_vector(AccxDP, AccxDP'length);
      RegistersxD(3) <= "0000000000000000000000000000000" & MulRunningxS;
      MulStartxS     <= '0';

      case state is
        -----------------------------------------------------------------------
        -- get first message from OS
        -----------------------------------------------------------------------
        when STATE_GET_VALS =>
          osif_mbox_get(i_osif, o_osif, MBOX_RECV, vals, done);
          if done then
            if (vals = X"FFFFFFFF") then
              state <= STATE_THREAD_EXIT;
            else
              case vals(31 downto 30) is
                when "00" =>
                  state <= STATE_WRITE;
                when "01" =>
                  state <= STATE_MEM_WRITE;
                when "10" =>
                  state <= STATE_READ;
                when "11" =>
                  state <= STATE_MEM_READ;
                when others =>
                  state <= STATE_GET_VALS;
              end case;
            end if;

            vals(31 downto 30) <= "00";  -- reset the last two bits, so that we
                                         -- can use it as address
          end if;


          ---------------------------------------------------------------------
          -- get second message from OS
          ---------------------------------------------------------------------
        when STATE_WRITE =>
          osif_mbox_get(i_osif, o_osif, MBOX_RECV, msg, done);
          if done then
            if msg = X"FFFFFFFF" then
              state <= STATE_THREAD_EXIT;
            elsif msg = X"00000001" and vals(1 downto 0) = "11" then
              state <= STATE_START_MUL;
            else
              RegistersxD(conv_integer(unsigned(vals(1 downto 0)))) <= msg;

              state <= STATE_GET_VALS;
            end if;
          end if;

          ---------------------------------------------------------------------
          -- send msg with register content to OS
          ---------------------------------------------------------------------
        when STATE_READ =>
          osif_mbox_put(i_osif, o_osif, MBOX_SEND,
                        RegistersxD(conv_integer(unsigned(vals(1 downto 0)))),
                        ignore, done);
          if done then
            state <= STATE_GET_VALS;
          end if;

          ---------------------------------------------------------------------
          -- Copy main memory to local memory
          ---------------------------------------------------------------------
        when STATE_MEM_READ =>
          memif_read(i_ram, o_ram, i_memif, o_memif, vals, X"00000000",
                     conv_std_logic_vector(C_LOCAL_RAM_SIZE_IN_BYTES, 24), done);

          if done then
            state <= STATE_FINISHED;
          end if;

          ---------------------------------------------------------------------
          -- Copy local memory to main memory
          ---------------------------------------------------------------------
        when STATE_MEM_WRITE =>
          memif_write(i_ram, o_ram, i_memif, o_memif, X"00000000", vals,
                      conv_std_logic_vector(C_LOCAL_RAM_SIZE_IN_BYTES, 24), done);

          if done then
            state <= STATE_FINISHED;
          end if;

          ---------------------------------------------------------------------
          -- Start Multiplier
          ---------------------------------------------------------------------
        when STATE_START_MUL =>
          MulStartxS <= '1';
          state      <= STATE_GET_VALS;

          ---------------------------------------------------------------------
          -- Send finished message
          ---------------------------------------------------------------------
        when STATE_FINISHED =>
          osif_mbox_put(i_osif, o_osif, MBOX_SEND,
                        X"00000001",
                        ignore, done);
          if done then
            state <= STATE_GET_VALS;
          end if;

          ---------------------------------------------------------------------
          -- thread exit
          ---------------------------------------------------------------------
        when STATE_THREAD_EXIT =>
          osif_thread_exit(i_osif, o_osif);
      end case;
    end if;
  end process;

end architecture;
