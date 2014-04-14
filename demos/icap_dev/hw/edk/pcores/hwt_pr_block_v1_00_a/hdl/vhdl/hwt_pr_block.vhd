library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

library proc_common_v3_00_a;
use proc_common_v3_00_a.proc_common_pkg.all;

library reconos_v3_00_b;
use reconos_v3_00_b.reconos_pkg.all;

entity hwt_pr_block is
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

architecture implementation of hwt_pr_block is
  type STATE_TYPE is (STATE_GET_VALS, STATE_WRITE, STATE_READ, STATE_THREAD_EXIT);

  constant MBOX_RECV : std_logic_vector(C_FSL_WIDTH-1 downto 0) := x"00000000";
  constant MBOX_SEND : std_logic_vector(C_FSL_WIDTH-1 downto 0) := x"00000001";

  signal state  : STATE_TYPE;
  signal i_osif : i_osif_t;
  signal o_osif : o_osif_t;

  signal ignore : std_logic_vector(C_FSL_WIDTH-1 downto 0);

  signal vals : std_logic_vector(31 downto 0);
  signal msg  : std_logic_vector(31 downto 0);

  -----------------------------------------------------------------------------
  -- registers
  -----------------------------------------------------------------------------
  type   reg_t is array (0 to 3) of std_logic_vector(31 downto 0);
  signal RegistersxD : reg_t;
begin

  -- do not use memory interface (memif)
  FIFO32_M_Data <= (others => '0');
  FIFO32_S_Rd   <= '0';
  FIFO32_M_Wr   <= '0';

  fsl_setup(i_osif, o_osif, OSFSL_S_Data, OSFSL_S_Exists, OSFSL_M_Full, OSFSL_M_Data, OSFSL_S_Read, OSFSL_M_Write, OSFSL_M_Control);

  -- os and memory synchronisation state machine
  reconos_fsm : process (clk, rst, o_osif) is
    variable done : boolean;
  begin
    if rst = '1' then
      vals  <= (others => '0');
      osif_reset(o_osif);
      state <= STATE_GET_VALS;
      done  := false;
    elsif rising_edge(clk) then

      -- default assignment
      RegistersxD(2) <= RegistersxD(0) + RegistersxD(1);
      RegistersxD(3) <= RegistersxD(3) + 1;

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
              if vals(31) = '1' then
                -- read mode
                state <= STATE_READ;
              else
                state <= STATE_WRITE;
              end if;
            end if;
          end if;
          ---------------------------------------------------------------------
          -- get second message from OS
          ---------------------------------------------------------------------
        when STATE_WRITE =>
          osif_mbox_get(i_osif, o_osif, MBOX_RECV, msg, done);
          if done then
            if msg = X"FFFFFFFF" then
              state <= STATE_THREAD_EXIT;
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
          -- thread exit
          ---------------------------------------------------------------------
        when STATE_THREAD_EXIT =>
          osif_thread_exit(i_osif, o_osif);
      end case;
    end if;
  end process;
  
end architecture;
