library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ips is
	generic (
		RECONOS_OSIF_MBOX_WIDTH	:	integer := 32
	);
	port (
		rst                   	:	in 	std_logic;
		clk                   	:	in 	std_logic;
		rx_ll_sof             	:	in 	std_logic;
		rx_ll_eof             	:	in 	std_logic;
		rx_ll_data            	:	in 	std_logic_vector(7 downto 0);
		rx_ll_src_rdy         	:	in 	std_logic;
		rx_ll_dst_rdy         	:	out	std_logic;
		tx_ll_sof             	:	out	std_logic;
		tx_ll_eof             	:	out	std_logic;
		tx_ll_data            	:	out	std_logic_vector(7 downto 0);
		tx_ll_src_rdy         	:	out	std_logic;
		tx_ll_dst_rdy         	:	in 	std_logic;
		stat_recv_packets     	:	out	std_logic_vector(RECONOS_OSIF_MBOX_WIDTH-1 downto 0);
		stat_forw_packets     	:	out	std_logic_vector(RECONOS_OSIF_MBOX_WIDTH-1 downto 0);
		stat_drop_packets     	:	out	std_logic_vector(RECONOS_OSIF_MBOX_WIDTH-1 downto 0);
		config_header_length  	:	in 	std_logic_vector(RECONOS_OSIF_MBOX_WIDTH-1 downto 0)
	);
end ips;


architecture implementation of ips is

	-- some constants
	constant	RESET       	:	std_logic	:= '1';	-- define if rst is active low or active high
	constant	GOOD_FORWARD	:	std_logic	:= '1';	-- used constants instead of a "type" to simplify feeding it into a FIFO of std_logic_vector's.
	constant	EVIL_DROP   	:	std_logic	:= '0';	
	constant	PACKET_WIDTH	:	integer  	:= 10; 	-- width of data + control bits (sof, eof, etc.)
	constant	RESULT_WIDTH	:	integer  	:= 1;  	-- width of the result (good or evil, note that all results in the FIFO have to be valid!)

	constant	PACKET_MAX_LENGTH	:	integer	:= 2000;	-- max. length of a packet in bytes, will be the size of the packet FIFO
	constant	PACKET_MIN_LENGTH	:	integer	:= 64;  	-- Minimum length of a packet in bytes.
	constant	HEADER_MAX_LENGTH	:	integer	:= 1000;	-- max. length of the header in bytes, needed to skip the header. 

	signal  	packet_fifo_full       	:	std_logic;
	signal  	packet_fifo_empty      	:	std_logic;
	signal  	packet_fifo_read       	:	std_logic;
	signal  	packet_fifo_write      	:	std_logic;
	signal  	packet_fifo_in_packet  	:	std_logic_vector(PACKET_WIDTH-1 downto 0); 
	signal  	packet_fifo_out_packet 	:	std_logic_vector(PACKET_WIDTH-1 downto 0); 
	signal  	out_packet_eof         	:	std_logic; -- intermediate signals, needed because we need to write and read to them. 
	signal  	result_fifo_empty      	:	std_logic;
	signal  	result_fifo_read       	:	std_logic; 
	signal  	result_fifo_out_packet 	:	std_logic_vector(RESULT_WIDTH-1 downto 0); 
	signal  	data_valid             	:	std_logic; -- internal input data valid signal. See receivercontrol for what it means.
	signal  	receiver_ready         	:	std_logic; -- intermediate signal for rx_ll_dst_rdy, needed because we need to write and read to them. 
	signal  	packet_inspection_ready	:	std_logic;
	signal   packet_fifo_fill : std_logic_vector(15 downto 0);	
	signal  	packet_fifo_rem  : std_logic_vector(15 downto 0);
	signal   result_fifo_fill : std_logic_vector(7 downto 0);	
	signal  	result_fifo_rem  : std_logic_vector(7 downto 0);

	-- intermediate signal
	signal	src_rdy	:	std_logic;
	signal	src_rdy_next	:	std_logic;


	-- sender control states
	type    	sendercontrol_type	is	( idle, drop, send_stalled, wait_tx_dst_rdy, send_before_firstbyte, send_sof, 
						send_byte_2, send_nextbyte, handle_last_byte,done); 
	signal  	sender_state      	: 	sendercontrol_type;
	signal  	sender_next_state 	: 	sendercontrol_type; 
	signal  	result            	: 	std_logic;	-- possible outcomes of the packet inspection are defined in the constants above. 
	signal  	result_valid      	: 	std_logic;	-- Note that the result is futile as long as the result_valid bit is not set.


	-- log data signals: packet counters.
	-- all "current" signals are already defined as output ports
	signal	count_received_packets      	:	std_logic_vector(RECONOS_OSIF_MBOX_WIDTH-1 downto 0);
	signal	count_forwarded_packets     	:	std_logic_vector(RECONOS_OSIF_MBOX_WIDTH-1 downto 0);
	signal	count_dropped_packets       	:	std_logic_vector(RECONOS_OSIF_MBOX_WIDTH-1 downto 0);
	signal	count_received_packets_next 	:	std_logic_vector(RECONOS_OSIF_MBOX_WIDTH-1 downto 0);
	signal	count_forwarded_packets_next	:	std_logic_vector(RECONOS_OSIF_MBOX_WIDTH-1 downto 0);
	signal	count_dropped_packets_next  	:	std_logic_vector(RECONOS_OSIF_MBOX_WIDTH-1 downto 0);

	--signal	header_length	:	integer range 0 to HEADER_MAX_LENGTH;
	signal  	first_byte	:	std_logic_vector(7 downto 0);

	--attributes
	attribute buffer_type: string;
	attribute buffer_type of sender_state: signal is "bufr";

   ------------------------------------------------------------------------------------------------------------------
	signal rx_sof                   	:	std_logic;
	signal rx_eof                   	:	std_logic;
	signal rx_data                  	:	std_logic_vector(7 downto 0);
	signal rx_data_valid            	:	std_logic;	-- source ready
	signal rx_packetinspection_ready	:	std_logic;	-- destination ready
	signal tx_result    	:	std_logic; -- from the outside this interface looks like a FIFO
	signal tx_result_valid	:	std_logic;
	signal tx_result_utf8    	:	std_logic; -- from the outside this interface looks like a FIFO
	signal tx_result_valid_utf8	:	std_logic;
	signal tx_fifo_empty	:	std_logic;
	signal tx_fifo_read 	:	std_logic;
	signal rx_header_length   	:		integer	range 0 to HEADER_MAX_LENGTH+2	:= 1;
	signal tx_data :	std_logic_vector(7 downto 0);
	signal tx_eof : std_logic;
	signal store_tx_data_1 :	std_logic_vector(7 downto 0);
	
	signal   	header_length        	:  	integer	range 0 to HEADER_MAX_LENGTH+2; 
	signal   	skipheader_count     	:  	integer	range 0 to HEADER_MAX_LENGTH+2; 
	signal   	skipheader_next_count	:  	integer	range 0 to HEADER_MAX_LENGTH+2; 
	type     	skipheader_type      	is(	wait_for_sof,header_bytes, data_bytes); 
	signal   	skipheader_state     	:  	skipheader_type;	
	signal   	skipheader_next_state	:  	skipheader_type; 

	signal	check_me  	:	std_logic; 
	signal	fifo_read 	:	std_logic; -- one fifo_read for all FIFOs is enough.
	signal	fifo_empty	:	std_logic; -- intermediate signal for tx_fifo_empty

	signal	ca_ready_1     	:	std_logic; -- n'th content analyser block ready
	signal	result_1       	:	std_logic; -- result output of the n'tn content analyser block, input of the n'th FIFO
	signal	result_valid_1 	:	std_logic; -- valid bit of result_n
	signal	queued_result_1	:	std_logic; -- queued version of result_1, output of the FIFO
	signal	fifo_full_1    	:	std_logic; -- read, write, full and empty signal for the n'th FIFO
	signal	fifo_empty_1   	:	std_logic; 
	signal	fifo_write_1   	:	std_logic; 
	signal	fifo_in_1 	:	std_logic_vector(RESULT_WIDTH-1 downto 0);
	signal	fifo_out_1	:	std_logic_vector(RESULT_WIDTH-1 downto 0);
	signal	rx_ca_ready    	:	std_logic;
	-------------------------------------------------------------------------------------------------------------------
	type  	utf8_state_type	is( unknown_idle, good,evil,evil_wait,examine_2nd_byte_3, examine_2nd_byte_4);
	signal	state_utf8         	:  	utf8_state_type; 
	signal	next_state_utf8    	:  	utf8_state_type;
	signal ignore_packet : std_logic;
	signal blocked_in_last_byte : std_logic;
	signal ensure_eof : std_logic;

	-- Define what to do when EOF arrives while analysing a multibyte character.
	constant	SAFE_STATE	:	utf8_state_type	:= evil; -- Default is evil.

	-- include components

	type receive_state_type	is( wait_sof, store_data_to_packet_fifo,wait_sof_2);
	signal receiver_state : receive_state_type := wait_sof;

	component fifo32 is 
	generic (
		C_FIFO32_WORD_WIDTH         	:	integer	:= PACKET_WIDTH;
		C_FIFO32_DEPTH              	:	integer := 4;
		C_FIFO32_CONTROLSIGNAL_WIDTH	:	integer	:= 16;
		CLOG2_FIFO32_DEPTH          	:	integer := 4;
		C_FIFO32_SAFE_READ_WRITE    	:	boolean	:= true
	);
		port (
		Rst           	:	in	std_logic;
		FIFO32_S_Clk  	:	in 	std_logic;                                                	-- clock and data signals
		FIFO32_M_Clk  	:	in 	std_logic;                                                	
		FIFO32_S_Data 	:	out	std_logic_vector(C_FIFO32_WORD_WIDTH-1 downto 0);         	
		FIFO32_M_Data 	:	in 	std_logic_vector(C_FIFO32_WORD_WIDTH-1 downto 0);         	
		FIFO32_S_Fill 	:	out	std_logic_vector(C_FIFO32_CONTROLSIGNAL_WIDTH-1 downto 0);	-- # elements in the FIFO. 0 means FIFO is empty.
		FIFO32_M_Rem  	:	out	std_logic_vector(C_FIFO32_CONTROLSIGNAL_WIDTH-1 downto 0);	-- remaining free space. 0 means FIFO is full.
		FIFO32_S_Full 	:	out	std_logic;                                                	-- FIFO full signal
		FIFO32_M_Empty	:	out	std_logic;                                                	-- FIFO empty signal
		FIFO32_S_Rd   	:	in 	std_logic;                                                	-- output data ready
		FIFO32_M_Wr   	:	in 	std_logic   
		);
	end component;

   --------------------------
	
	component icon
	port (
		control0 : inout std_logic_vector(35 downto 0)
	);
	end component;

	component ila
	port (
		control : inout std_logic_vector(35 downto 0);
		clk   : in std_logic;
		trig0 : in std_logic_vector( 3 downto 0);
		trig1 : in std_logic_vector( 7 downto 0);
		trig2 : in std_logic_vector( 3 downto 0);
		trig3 : in std_logic_vector( 7 downto 0);
		trig4 : in std_logic_vector( 7 downto 0);
		trig5 : in std_logic_vector( 7 downto 0);
		trig6 : in std_logic_vector( 3 downto 0);
		trig7 : in std_logic_vector(31 downto 0);
		trig8 : in std_logic_vector(15 downto 0);
		trig9 : in std_logic_vector(15 downto 0);
		trig10: in std_logic_vector(15 downto 0)
	);
	end component;
	
	signal trig0 : std_logic_vector( 3 downto 0);
	signal trig1 : std_logic_vector( 7 downto 0);
	signal trig2 : std_logic_vector( 3 downto 0);
	signal trig3 : std_logic_vector( 7 downto 0);
	signal trig4 : std_logic_vector( 7 downto 0);
	signal trig5 : std_logic_vector( 7 downto 0);
	signal trig6 : std_logic_vector( 3 downto 0);
	signal trig7 : std_logic_vector(31 downto 0);
	signal trig8 : std_logic_vector(15 downto 0);
	signal trig9 : std_logic_vector(15 downto 0);
	signal trig10: std_logic_vector(15 downto 0);
	signal control : std_logic_vector(35 downto 0);
	
	signal tx_ll_sof_2 : std_logic;
	signal tx_ll_sof_next : std_logic;
	signal tx_ll_data_2 : std_logic_vector( 7 downto 0);
	
	signal utf8_step : std_logic_vector(3 downto 0);
	signal send_step : std_logic_vector(3 downto 0);
	signal skip_header_step: std_logic_vector(1 downto 0);
	signal utf8_step_next : std_logic_vector(3 downto 0);
	signal send_step_next : std_logic_vector(3 downto 0);
	signal skip_header_step_next: std_logic_vector(1 downto 0);
	signal receiver_step : std_logic_vector(1 downto 0); 
	signal reset_tx_signals : std_logic;

begin

	icon_i : icon
	port map (
		control0 => control
	);
	
	ila_i : ila
	port map (
		control => control,
		clk => clk,
		trig0 => trig0,
		trig1 => trig1,
		trig2 => trig2,
		trig3 => trig3,
		trig4 => trig4,
		trig5 => trig5,
		trig6 => trig6,
		trig7 => trig7,
		trig8 => trig8,
		trig9 => trig9,
		trig10 => trig10
	);

	trig0(3) <= rx_ll_sof;
	trig0(2) <= rx_ll_eof;
	trig0(1) <= rx_ll_src_rdy;
	trig0(0) <= receiver_ready;
	
	trig1 <= rx_ll_data;
	
	trig2(3) <= tx_ll_sof_2;
	trig2(2) <= tx_eof; --out_packet_eof or ensure_eof;
	trig2(1) <= src_rdy;
	trig2(0) <= tx_ll_dst_rdy;
	
	trig3 <= tx_ll_data_2;
	
	trig4 <= config_header_length(7 downto 0);
	
	trig5(7 downto 4) <= utf8_step(3 downto 0);
	trig5(3 downto 0) <= send_step(3 downto 0);
	
	trig6(3 downto 2) <= rst & '0'; 
	trig6(1 downto 0) <= skip_header_step(1 downto 0);
	
	trig7(31 downto 22) <= packet_fifo_in_packet(9 downto 0);
	trig7(21 downto 12) <= packet_fifo_out_packet(9 downto 0);
	trig7(11)           <= ignore_packet;
	trig7(10 downto  0) <= packet_fifo_fill(10 downto 0);
	
	trig8(15 downto  5) <= packet_fifo_rem(10 downto 0);
	trig8(4) <= '0';
	trig8(3) <= packet_fifo_full;
	trig8(2) <= packet_fifo_empty;
	trig8(1) <= packet_fifo_read;
	trig8(0) <= packet_fifo_write;
	
	trig9(15) <= fifo_in_1(0);
	trig9(14) <= fifo_out_1(0);
	trig9(13) <= fifo_full_1;
	trig9(12) <= fifo_empty_1;
	trig9(11) <= fifo_read;
	trig9(10) <= fifo_write_1;
	trig9( 9 downto 8) <= receiver_step;
	trig9(7 downto 4) <= result_fifo_fill(3 downto 0);
	trig9(3 downto 0) <= result_fifo_rem(3 downto 0);
	
	trig10(15 downto 0)<= count_received_packets(7 downto 0)& 
	           count_forwarded_packets(3 downto 0) & count_dropped_packets(3 downto 0);

	-- define a "packet" as data, sof and eof signals.
	-- packets will not be sent directly, but be stored in a fifo buffer until all checks are done.
	tx_ll_src_rdy 	<=	src_rdy;
	--out_packet_eof	<=	'0' when (sender_state = idle or rst=RESET  )  else packet_fifo_out_packet(9); 
	tx_ll_eof     	<=	tx_eof; --out_packet_eof or ensure_eof;
	--packet_fifo_write	<=	data_valid;


	stat_recv_packets	<=	count_received_packets;
	stat_forw_packets	<=	count_forwarded_packets;
	stat_drop_packets	<=	count_dropped_packets;
	header_length  	<=	to_integer(unsigned(config_header_length));

	-- a FIFO which can hold at least one packet
	packet_fifo : fifo32
	generic map(
		C_FIFO32_WORD_WIDTH           	=> PACKET_WIDTH,
		C_FIFO32_DEPTH                	=> PACKET_MAX_LENGTH,	-- TODO packet buffer size / min. packet size
		CLOG2_FIFO32_DEPTH            	=> 11,               	-- TODO check. probably ok like this.
		C_FIFO32_CONTROLSIGNAL_WIDTH	   => 16,
		C_FIFO32_SAFE_READ_WRITE      	=> true
	)
	port map(
		Rst            	=> rst, 
		FIFO32_S_Clk   	=> clk,
		FIFO32_M_Clk   	=> clk,
		FIFO32_S_Data  	=> packet_fifo_out_packet,	-- packet vector, i.e. data / SOF / EOF
		FIFO32_M_Data  	=> packet_fifo_in_packet, 
		FIFO32_S_Fill     => packet_fifo_fill,
		FIFO32_M_Rem      => packet_fifo_rem,
		FIFO32_S_Full  	=> packet_fifo_full, 
		FIFO32_M_Empty 	=> packet_fifo_empty, 
		FIFO32_S_Rd    	=> packet_fifo_read, 
		FIFO32_M_Wr    	=> packet_fifo_write
	);
	
	-- processes

	-- "sender control" state machine.
	-- Apart from the actual content analysis, this process is the most important of the IPS entity.
	-- It controls the entire data flow, i.e. it checks results and sends or drops packets.
	-- 
	-- overview of the states:
	--
	-- idle                 	(initial state). 
	--                      	The data FIFO or the result FIFO is empty.
	--                      	Nothing to do so far. 
	-- drop                 	Result is known to be evil. 
	--                      	Read the next byte from the FIFO and drop it, until EOF.
	-- send_nextbyte        	packet is known to be good.
	--                      	Read the next byte from the FIFO and send it, until EOF.  
	-- send_stalled         	We like to send, but the receiver is not ready. 
	--                      	Wait until it becomes ready. 
	-- send_before_firstbyte	Belong to a Workaround.
	--     and send_sof     	Without the workaround, the first byte arrives twice in the HW. 
	--                      	This code was adapted from hwt_s2h
	--                      	Note that in the simulator, this "bug" cannot be found. It looks like doing the wrong thing now, in the simulator, but it works in the HW. 
	tx_ll_data	<=	"00000000" when (rst=RESET or ignore_packet='1') else tx_data;
	tx_ll_sof	<=	'0' when (rst=RESET or ignore_packet='1' or src_rdy='0' or reset_tx_signals='1') else packet_fifo_out_packet(8);
	out_packet_eof	<= '0' when (rst=RESET or ignore_packet='1' or src_rdy='0' or reset_tx_signals='1') else 	packet_fifo_out_packet(9);
	
	tx_ll_sof_2 <=	'0' when (rst=RESET or ignore_packet='1' or src_rdy='0' or reset_tx_signals='1') else packet_fifo_out_packet(8);
	tx_ll_data_2	<=	"00000000" when (rst=RESET or ignore_packet='1') else  tx_data; --packet_fifo_out_packet(7 downto 0);

	send_proc : process(clk, rst) is
		variable tmp : unsigned(31 downto 0);
	begin
		if (rst = RESET) then
			send_step      <= "0000";
			sender_state	<= idle;
			count_forwarded_packets   	<= (others => '0');
			count_dropped_packets     	<= (others => '0');
			src_rdy <= '0';
			result_fifo_read	<= '0';
			packet_fifo_read	<= '0';
			ignore_packet <= '0';
			reset_tx_signals <= '0';
			blocked_in_last_byte <= '0';
			tx_data <= (others => '0');
			store_tx_data_1 <= (others => '0');
			ensure_eof <= '0';
			tx_eof <= '0'; --out_packet_eof or ensure_eof;
		elsif (rising_edge(clk)) then
			tx_eof <= out_packet_eof or ensure_eof;
			result_fifo_read	<= '0';
			packet_fifo_read	<= '0'; 
			src_rdy         	<= '0';
			ignore_packet     <= '0';
			ensure_eof <= '0';
			case sender_state is

				when idle =>
					tx_data <= packet_fifo_out_packet(7 downto 0);
					send_step <= "0001";
					if (ensure_eof = '1') then
						ensure_eof <= '0';
					end if;
					blocked_in_last_byte <= '0';
					reset_tx_signals <= '0';
					packet_fifo_read	<= '0';
					store_tx_data_1 <= (others => '0');
					if (result_fifo_empty = '0' and packet_fifo_empty = '0') then
								result_fifo_read <= '1';
								if (queued_result_1 = EVIL_DROP) then
									ignore_packet <= '1';
									sender_state <= drop;
									--send_step <= "0111";
								else
									--send_step <= "1110";
									sender_state   	<= send_before_firstbyte; 
								end if;
					end if; 
					
				  when send_before_firstbyte =>
					tx_data <= packet_fifo_out_packet(7 downto 0);
					send_step <= "0010";
					reset_tx_signals  <= '0';
					packet_fifo_read	<= '0'; 
					result_fifo_read 	<= '0'; 
					src_rdy     	<= '1'; 
					--if tx_ll_dst_rdy = '1' and packet_fifo_empty = '0' then -- TRY TO REMOVE THREE BYTE BUG
						sender_state	<= wait_tx_dst_rdy;
					--end if; -- TRY TO REMOVE THREE BYTE BUG
					
				when wait_tx_dst_rdy =>
					tx_data <= packet_fifo_out_packet(7 downto 0);
					send_step <= "0011";
					reset_tx_signals  <= '0';
					result_fifo_read	<= '0';
					packet_fifo_read	<= '0'; 
					src_rdy     	<= '1';
					if tx_ll_dst_rdy = '1' and packet_fifo_empty = '0' then
						packet_fifo_read 	<= '1'; 
						--send_step <= "0010";
						sender_state	<= send_nextbyte;
						src_rdy     	<= '1'; 
					else
						packet_fifo_read 	<= '1';
						src_rdy <= '0';
						sender_state	<= send_stalled;
					end if;
					
				when send_stalled => 
					--tx_data <= packet_fifo_out_packet(7 downto 0);
					src_rdy <= '0';
					send_step <= "0111";
					store_tx_data_1 <= packet_fifo_out_packet(7 downto 0);
					sender_state <= send_byte_2;
					
				when send_byte_2 =>
					send_step <= "1000";
					reset_tx_signals  <= '0';
					result_fifo_read	<= '0';
					packet_fifo_read	<= '0'; 
					src_rdy     	<= '0';
					if tx_ll_dst_rdy = '1' and packet_fifo_empty = '0' then
						src_rdy     	<= '1';
						tx_data <= store_tx_data_1;
						packet_fifo_read 	<= '1'; 
						--send_step <= "0010";
						sender_state	<= send_nextbyte;
						src_rdy     	<= '1'; 
					end if;
					
				when send_sof =>
					tx_data <= packet_fifo_out_packet(7 downto 0);
					send_step <= "0100";
					reset_tx_signals  <= '0';
					result_fifo_read	<= '0'; 
					src_rdy     	<= '1';
				if tx_ll_dst_rdy = '1'  and packet_fifo_empty = '0' then
					packet_fifo_read	<= '1';
					sender_state	<= send_nextbyte;
					--send_step <= "0100";
				end if;

				when send_nextbyte =>
					tx_data <= packet_fifo_out_packet(7 downto 0);
					send_step <= "0101";
					reset_tx_signals  <= '0';
					result_fifo_read	<= '0';
					packet_fifo_read	<= '1'; 
					src_rdy     	<= '1'; 
					blocked_in_last_byte <= '0';
					if (packet_fifo_out_packet(9)='1' and tx_ll_dst_rdy = '1' ) then 
						src_rdy  <= '1'; 
						--packet_fifo_read	<= '0';
						--sender_state <= handle_last_byte; 
						--send_step <= "1001";
						reset_tx_signals  <= '1';
						packet_fifo_read	<= '0';
						sender_state <= done;
						--send_step <= "0001";
						tmp := unsigned(count_forwarded_packets) + 1;
						count_forwarded_packets <= std_logic_vector(tmp);
					elsif (packet_fifo_out_packet(9)='1') then
						-- blocked last byte in packet
						src_rdy  <= '1';
						packet_fifo_read	<= '0';
						blocked_in_last_byte <= '1';
						sender_state <= handle_last_byte; 
						--send_step <= "1001";
						tmp := unsigned(count_forwarded_packets) + 1;
						count_forwarded_packets <= std_logic_vector(tmp);
					elsif (tx_ll_dst_rdy = '1'  and packet_fifo_empty = '0') then 
						packet_fifo_read	<= '1';
						sender_state <= send_nextbyte; 
						--send_step <= "0100";
					else
						packet_fifo_read	<= '0';
					end if; 
					
				when done => 
					src_rdy     	<= '0';
					reset_tx_signals  <= '1';
					result_fifo_read	<= '0';
					packet_fifo_read	<= '0'; 
					send_step <= "1110";
					sender_state <= idle;
					
				when handle_last_byte =>
					tx_data <= packet_fifo_out_packet(7 downto 0);
					send_step <= "0110";
					reset_tx_signals  <= '0';
					src_rdy  <= '1';
					if (tx_ll_dst_rdy = '1' ) then 
						ensure_eof <= '1';
						src_rdy  <= '1'; 
						packet_fifo_read	<= '1';
						sender_state <= idle; 
						--send_step <= "0001";
					end if;					

				when drop =>
					tx_data <= (others=>'0');
					send_step <= "1111";
					reset_tx_signals  <= '0';
					ignore_packet <= '1';
					result_fifo_read	<= '0';
					packet_fifo_read	<= '1'; 
					src_rdy         	<= '0';
					if (packet_fifo_out_packet(9) = '1') then 
						packet_fifo_read	<= '0'; 
						sender_state <= idle; 
						--send_step <= "0001";
						tmp := unsigned(count_dropped_packets) + 1;
						count_dropped_packets <= std_logic_vector(tmp);
					end if; 

				when others => 
					send_step <= "1100";
					tx_data <= packet_fifo_out_packet(7 downto 0);
					reset_tx_signals  <= '0';
					result_fifo_read	<= '0';
					packet_fifo_read	<= '0'; 
					src_rdy        	<= '0'; 
			end case; -- sender_state
		end if;
	
	end process;


	receivercontrol : process (clk,rst,rx_ll_data,rx_ll_sof,rx_ll_eof) is
		variable tmp : unsigned(31 downto 0);
	begin
		if (rst=RESET) then
			count_received_packets <= (others=>'0');
			rx_ll_dst_rdy <= '0';
			receiver_ready   	<=	'0';
			packet_fifo_write <= '0';
			receiver_state <= wait_sof;
			receiver_step <= "00";
			packet_fifo_in_packet(7 downto 0)     	<=	rx_ll_data;
			packet_fifo_in_packet(8)              	<=	rx_ll_sof;
			packet_fifo_in_packet(9)              	<=	rx_ll_eof;
		elsif (rising_edge(clk)) then
			packet_fifo_in_packet(7 downto 0)     	<=	rx_ll_data;
			packet_fifo_in_packet(8)              	<=	rx_ll_sof;
			packet_fifo_in_packet(9)              	<=	rx_ll_eof;
			rx_ll_dst_rdy    	<=	'1';
			receiver_ready   	<=	'1';
			packet_fifo_write <= '0';
			receiver_state <= receiver_state;
			case receiver_state is
				when wait_sof =>
					rx_ll_dst_rdy    	<=	packet_fifo_empty;
					receiver_ready   	<=	packet_fifo_empty;
					receiver_step <= "01";
					--if (rx_ll_src_rdy='1' and packet_fifo_full='0' and rx_ll_sof='1') then
					if (rx_ll_src_rdy='1' and packet_fifo_empty='0') then -- new: try to fix bug (doubling the first byte of packet)
						receiver_state <= wait_sof_2;                      -- new: try to fix bug (doubling the first byte of packet)
						packet_fifo_write <= '0';                          -- new: try to fix bug (doubling the first byte of packet)
					elsif (rx_ll_src_rdy='1' and packet_fifo_empty='1' and rx_ll_sof='1') then
						tmp := unsigned(count_received_packets) + 1;
						count_received_packets <= std_logic_vector(tmp);
						rx_ll_dst_rdy    	<=	'1';
						receiver_ready   	<=	'1';
						packet_fifo_write <= '1';
						receiver_state <= store_data_to_packet_fifo;
					end if;

				when wait_sof_2 => -- new: try to fix bug (doubling the first byte of packet)
					rx_ll_dst_rdy    	<=	packet_fifo_empty;
					receiver_ready   	<=	packet_fifo_empty;
					receiver_step <= "11";
					if (rx_ll_src_rdy='1' and packet_fifo_empty='1' and rx_ll_sof='1') then
						tmp := unsigned(count_received_packets) + 1;
						count_received_packets <= std_logic_vector(tmp);
						rx_ll_dst_rdy    	<=	'1';
						receiver_ready   	<=	'1';
						packet_fifo_write <= '0';
						receiver_state <= store_data_to_packet_fifo;
					end if;					
				
				when store_data_to_packet_fifo =>
					receiver_step <= "10";
					if (rx_ll_src_rdy='1' and packet_fifo_full='0') then
						receiver_ready   	<=	'1';
						rx_ll_dst_rdy    	<=	'1';
						packet_fifo_write <= '1';
						if (rx_ll_eof = '1') then
							packet_fifo_write <= '1';
							receiver_state <= wait_sof;
							rx_ll_dst_rdy    	<=	'0';
							receiver_ready   	<=	'0';
						end if;
					else
						packet_fifo_write <= '0';
						--receiver_ready  <= '0';
						--rx_ll_dst_rdy    	<=	'0';
					end if;
				
			end case;
		end if;
	end process;
	
	-----------------------------------------------------------------------------------------------------------------
	-- PACKET INSPECTION . VHD
	-----------------------------------------------------------------------------------------------------------------
	
	rx_sof                   	<=	rx_ll_sof;
	rx_eof                   	<=	rx_ll_eof;
	rx_data                  	<=	rx_ll_data;
	--rx_data_valid            	<=	data_valid;
	packet_inspection_ready    <= rx_packetinspection_ready;
	result                     <= tx_result;
	--tx_result <= tx_result_utf8;
	result_fifo_empty          <= tx_fifo_empty;
	tx_fifo_read             	<=	result_fifo_read;
	rx_header_length         	<=	header_length;
	
	-- instantiate a FIFO for each result.  TODO To be automatised...
	result_fifo_1 : fifo32
	generic map(
	  	C_FIFO32_WORD_WIDTH         	=> 1,
		C_FIFO32_CONTROLSIGNAL_WIDTH	=> 8, -- TODO
		C_FIFO32_DEPTH          	=> 32, --24, -- 1500/64 (worst case # packets in packet FIFO). -> packet fifo size is 2000 -> wrong
		CLOG2_FIFO32_DEPTH      	=> 5, --4(????), -- ceil(log2(depth))
		C_FIFO32_SAFE_READ_WRITE	=> true
		)
	port map(
		Rst         	=> rst, 
		FIFO32_S_Clk	=> clk,
		FIFO32_M_Clk	=> clk,
		FIFO32_S_Data  	=> fifo_out_1, 
		FIFO32_M_Data  	=> fifo_in_1, 
		FIFO32_S_Fill     => result_fifo_fill,
		FIFO32_M_Rem      => result_fifo_rem,
		FIFO32_S_Full  	=> fifo_full_1, 
		FIFO32_M_Empty 	=> fifo_empty_1, 
		FIFO32_S_Rd    	=> fifo_read, 
		FIFO32_M_Wr    	=> fifo_write_1
	);

-- do not check the header bytes.
	--
	-- header_bytes:	(initial state)
	--              	The current byte is a header byte.
	--              	Set check_me to '0'.
	-- data_bytes:  	The current byte is a data byte.
	--              	Set check_me to '1'.

	skipheader_memless : process(	skip_header_step,skipheader_state, rx_sof,rx_ll_src_rdy, rx_eof, rx_data_valid, skipheader_count,header_length,receiver_ready,packet_fifo_full,rst,rx_sof) is
	begin
		-- default: do nothing.
		skipheader_next_state	<=	skipheader_state;
		skip_header_step_next   <= skip_header_step;
		skipheader_next_count	<=	skipheader_count; 
		check_me             	<=	'0';

		--if (rx_ll_src_rdy = '1' and receiver_ready = '1') then
		if (rx_ll_src_rdy = '1' and packet_fifo_full='0') then
			case skipheader_state is
			
				when wait_for_sof => 
					skip_header_step_next   <= "01";
					skipheader_next_state	<=	wait_for_sof;
					skipheader_next_count   <= 0; 
					if (rx_sof = '1' ) then --and rx_ll_src_rdy='1'  and receiver_ready = '1' ) then
						skipheader_next_count   <= 2;
						if (header_length = 1) then
							skipheader_next_state	<=	data_bytes;
							skip_header_step_next   <= "11";
						else
							skipheader_next_state	<=	header_bytes;
							skip_header_step_next   <= "10";
						end if;
					end if;

				when header_bytes =>
					-- wait for SOF (on first byte only):
					--if (rx_sof = '1' or skipheader_count > 1) then
					--if ( rx_ll_src_rdy='1'  and receiver_ready = '1' ) then
						skipheader_next_count	<=	skipheader_count + 1;
						if (skipheader_count >= header_length) then 
							skipheader_next_state	<=	data_bytes; 
							skip_header_step_next   <= "11";
						else
							skipheader_next_state	<=	header_bytes;
							skip_header_step_next   <= "10";
						end if; 
					--end if; 

				when data_bytes =>
					check_me	<=	'1';
					-- wait for EOF.
					if (rx_eof = '1') then
						-- special case: if header length is 0, we won't need to skip anything.
						if (header_length = 0) then
							skipheader_next_state	<=	data_bytes;
							skip_header_step_next   <= "11";
						else
							--skipheader_next_state	<=	header_bytes;
							--skip_header_step_next   <= "01";
							skipheader_next_state	<=	wait_for_sof;
							skip_header_step_next   <= "01";
							skipheader_next_count	<=	1; -- init counter
						end if; 
					end if; 	
				end case ;
		else 
			skipheader_next_state	<= skipheader_state;
			skip_header_step_next   <= skip_header_step;
		end if;
	end process ; -- skipheader_memless


	skipheader_memzing : process( clk, rst ) is
	begin
	    if rst = RESET then
			--skipheader_count  	<= 1; 
			--skipheader_state  	<= header_bytes; 
			skipheader_count  	<= 0; 
			skipheader_state  	<= wait_for_sof;
			skip_header_step     <= "00";
	    elsif rising_edge(clk) then
			skipheader_count	<= skipheader_next_count;
			skipheader_state	<= skipheader_next_state;
			skip_header_step  <= skip_header_step_next;
	    end if;
	end process ; 



	fifo_write_1	<=	result_valid_1;
	--header_length  <=	rx_header_length; -- in bytes
	fifo_in_1(0)   <=	result_1;
	queued_result_1<=	fifo_out_1(0); 
	fifo_read    	<=	tx_fifo_read	and not fifo_empty; 
	tx_fifo_empty	<=	fifo_empty;

   rx_packetinspection_ready	<=   	ca_ready_1	and	not fifo_full_1;
	fifo_empty	<= fifo_empty_1;
	tx_result	<= result_1; 
	
	rx_data_valid	<=	check_me;
	--rx_ca_ready    	<=	ca_ready_1;
	ca_ready_1 <= rx_ca_ready;
	--tx_result      	<=	result_1;
	result_1 <= tx_result_utf8;
	--tx_result_valid	<=	result_valid_1;
	result_valid_1 <= tx_result_valid_utf8;
	
	-------------------------------------------------------------------------------------------------------------------------
	-- UTF-8 Non-shortest form attacks
	-------------------------------------------------------------------------------------------------------------------------
	rx_ca_ready	<=	'0' when (rst = RESET)	else '1';
	
	memless_utf8 : process(	state_utf8, rx_data,rx_eof, rx_data_valid,utf8_step) is
	begin
		next_state_utf8     	<= state_utf8; 
		utf8_step_next       <= utf8_step;
		tx_result_valid_utf8	<= '0';

		-- forward result and leave state on next clock cycle:
		case state_utf8 is
			when good =>
				tx_result_utf8      	<=	GOOD_FORWARD;
				tx_result_valid_utf8	<=	'1';
				utf8_step_next    <= "0000";
				next_state_utf8	<=	unknown_idle; 

			when evil =>
				tx_result_utf8      	<=	EVIL_DROP;
				tx_result_valid_utf8	<=	'1';
				
				if (rx_eof = '1') then
					utf8_step_next    <= "0001";
					next_state_utf8	<=	unknown_idle; 
				else
					utf8_step_next    <= "0101";
					next_state_utf8	<=	evil_wait; 
				end if ;

				when others => 
		end case; -- state_utf8

		-- the actual content analysis: 
		if (rx_data_valid='1') then 

			case state_utf8 is			

				when unknown_idle =>
					if (rx_data(7) = '0' or rx_data(7 downto 6) = "10") then
						if (rx_eof = '1') then
							utf8_step_next    <= "0100";
							next_state_utf8	<=	good; 
						else
							utf8_step_next    <= "0001";
							next_state_utf8	<=	unknown_idle; 
						end if ;
					end if ;

					-- Look for the first byte of a 2-byte character: "110x xxxx"
					if (rx_data(7 downto 5) = "110") then
						if (rx_data(4 downto 1) = "0000" )  then
							-- 7-bit character represented with 2 bytes instead of 1 }:-)
							utf8_step_next    <= "0111";
							next_state_utf8	<=	evil;
						else
							-- a regular 2-byte character O:-)
							if (rx_eof = '1') then
								utf8_step_next    <= "0100";
								next_state_utf8	<=	good; 
							else
								utf8_step_next    <= "0001";
								next_state_utf8	<=	unknown_idle; 
							end if ;
						end if ;
					end if ;

					-- Look for the first byte of a 3-byte character: "1110 xxxx"
					if (rx_data(7 downto 4) = "1110") then
						if (rx_data(3 downto 0) = "0000") then
							-- character can be up to 12 bits long, need to check the second byte.
							if (rx_eof = '1') then
								utf8_step_next    <= "0101";
								next_state_utf8	<=	SAFE_STATE; 
							else
								utf8_step_next    <= "0010";
								next_state_utf8	<=	examine_2nd_byte_3; 
							end if ;
						else -- i.e. rx_data(3 downto 0) contain at least one '1' Bit
							-- 13 bit or longer, i.e. this is a regular 3-byte character O:-)
							if (rx_eof = '1') then
								utf8_step_next    <= "0100";
								next_state_utf8	<=	good; 
							else
								utf8_step_next    <= "0001";
								next_state_utf8	<=	unknown_idle; 
							end if ;
						end if ;
								
					end if ;

					-- Look for the first byte of a 4-byte character: "1111 0xxx"
					if (rx_data(7 downto 3) = "11110") then
						if (rx_data(2 downto 0) = "000") then
							-- character can be up to 18 bit long, need to check the second byte.
							if (rx_eof = '1') then
								utf8_step_next    <= "0101";
								next_state_utf8	<=	SAFE_STATE; 
							else
								utf8_step_next    <= "0011";
								next_state_utf8	<=	examine_2nd_byte_4; 
							end if ;
						else -- i.e. rx_data(2 downto 0) contain at least one '1' Bit
							-- 19 bit or longer, i.e. this is a regular 4-byte character O:-)
							if (rx_eof = '1') then
								utf8_step_next    <= "0100";
								next_state_utf8	<=	good; 
							else
								utf8_step_next    <= "0001";
								next_state_utf8	<=	unknown_idle; 
							end if ;
						end if;
					end if;								

				when examine_2nd_byte_3 =>
					-- examine the 2nd byte of a 3-byte character
					if (rx_data(7 downto 5) = "100") then
						-- 11 bit character represented with 3 bytes instead of 2 }:-)
						utf8_step_next    <= "0111";
						next_state_utf8	<=	evil;
					else
						-- regular 3-byte character
						if (rx_eof = '1') then
							utf8_step_next    <= "0100";
							next_state_utf8	<=	good; 
						else
							utf8_step_next    <= "0001";
							next_state_utf8	<=	unknown_idle; 
						end if ;
					end if ;

				when examine_2nd_byte_4 =>
					-- examine the 2nd byte of a 3-byte character
					if (rx_data(7 downto 4) = "1000") then
						-- 16 bit character represented with 4 bytes instead of 3 }:-)
						utf8_step_next    <= "0111";
						next_state_utf8	<=	evil;
					else
						-- regular 4-byte character
						if (rx_eof = '1') then
							utf8_step_next    <= "0100";
							next_state_utf8	<=	good; 
						else
							utf8_step_next    <= "0001";
							next_state_utf8	<=	unknown_idle; 
						end if ;
					end if ;

				when evil_wait =>
					if (rx_eof = '1') then
						utf8_step_next    <= "0001";
						next_state_utf8	<=	unknown_idle; 
					else
						utf8_step_next    <= "0110";
						next_state_utf8	<=	evil_wait; 
					end if ;

				when others => 
			end case;
		end if ; 
	end process; 

	memzing_utf8 : process( clk, rst ) is
	begin
	    if rst = RESET then
			state_utf8	<=	unknown_idle;
			utf8_step 	<=	"0000";
	    elsif rising_edge(clk) then
			state_utf8	<=	next_state_utf8; 
			utf8_step   <= utf8_step_next;
	    end if;
	end process ; 

end architecture;
