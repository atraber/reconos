#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <assert.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <math.h>
#include <signal.h>

// ReconOS
#include "reconos.h"
#include "mbox.h"

#include "timing.h"

#include "icap_demo.h"




struct cmd_arguments_t g_arguments;


struct reconos_resource res[NUM_SLOTS][2];
struct reconos_hwt hwt[NUM_SLOTS];
struct mbox mb_in[NUM_SLOTS];
struct mbox mb_out[NUM_SLOTS];

struct pr_bitstream_t pr_bit[NUM_SLOTS][2];

int prblock_set(int slot, unsigned int reg, uint32_t value)
{
	mbox_put(&mb_in[slot], reg);
	mbox_put(&mb_in[slot], value);

	return 0;
}

int prblock_get(int slot, unsigned int reg)
{
  unsigned int ret;

	mbox_put(&mb_in[slot], reg | 0x80000000);

	ret = mbox_get(&mb_out[slot]);

  printf("In slot %d, register %X has value %08X\n", slot, reg, ret);

	return ret;
}

uint32_t g_prblock_mem[PRBLOCK_MEM_SIZE];

int prblock_mem_set(int slot, uint32_t value)
{
  if(slot == 0 || slot >= NUM_SLOTS) {
    printf("Slot %d does not contain a reconfigurable module\n", slot);
    return 0;
  }

  // uint32_t* mem = (uint32_t*)malloc(PRBLOCK_MEM_SIZE * sizeof(uint32_t));
  // if(mem == NULL) {
  //   printf("Memory alloc has failed\n");
  //   return 0;
  // }
  uint32_t* mem = g_prblock_mem;

  unsigned int i;
  for(i = 0; i < PRBLOCK_MEM_SIZE; i++)
    mem[i] = value;

	mbox_put(&mb_in[slot], ((unsigned int)mem) | 0xC0000000);

  // copy has finished
	mbox_get(&mb_out[slot]);

  // free(mem);

	return 0;
}

int prblock_mem_get(int slot, uint32_t value)
{
  if(slot == 0 || slot >= NUM_SLOTS) {
    printf("Slot %d does not contain a reconfigurable module\n", slot);
    return 0;
  }

  // test memory
  // uint32_t* mem = (uint32_t*)malloc(PRBLOCK_MEM_SIZE * sizeof(uint32_t));
  // if(mem == NULL) {
  //   printf("Memory alloc has failed\n");
  //   return 0;
  // }
  uint32_t* mem = g_prblock_mem;

  // set to different value
  unsigned int i;
  for(i = 0; i < PRBLOCK_MEM_SIZE; i++)
    mem[i] = 0x00000000;

  // flush our local cache, otherwise the values we get are probably invalid
  reconos_cache_flush();

	mbox_put(&mb_in[slot], ((unsigned int)mem) | 0x40000000);

  // copy has finished
	mbox_get(&mb_out[slot]);

  // check
  for(i = 0; i < PRBLOCK_MEM_SIZE; i++) {
    if(mem[i] != value) {
      printf("Memory contents different at index %d, expected %08X, actual %08X\n", i, value, mem[i]);
      return 0;
    }
  }

  // free(mem);

	return 1;
}

int test_prblock(int slot, int thread_id)
{
  if(slot == 0 || slot >= NUM_SLOTS) {
    printf("Slot %d does not contain a reconfigurable module\n", slot);
    return 0;
  }

  unsigned int ret, counter;
  prblock_set(slot, 0, 0x01003344);
  prblock_set(slot, 1, 0x01001122);

  // get result from register 2
  ret = prblock_get(slot, 2);

  // get counter value from register 3
  counter = prblock_get(slot, 3);
  
  switch(thread_id) {
  case ADD:
    if (ret==(0x01003344)+(0x01001122)) {
      printf("  # ADD: passed\n");
    } else {
      printf("  # ADD: failed\n");
      return 0;
    }
    break;

  case SUB:
    if (ret==(0x01003344)-(0x01001122)) {
      printf("  # SUB: passed\n");
    } else {
      printf("  # SUB: failed\n");
      return 0;
    }
    break;

  default:
    printf("Unknown thread_id %d\n", thread_id);
    return 0;
  }

  // // test memory
  // prblock_mem_set(slot, 0x11223344);

  // if(prblock_mem_get(slot, 0x11223344) == 0)
  //   printf("  # PRBLOCK: memory failed\n");

	return 1;
}

int reconfigure_prblock(int slot, int thread_id)
{
	timing_t t_start, t_stop;
  us_t t_check;

	int ret = -2;

	// send thread exit command
	mbox_put(&mb_in[slot],THREAD_EXIT_CMD);

  usleep(100);

  reconos_slot_reset(slot, 1);

  printf("Starting reconfiguration\n");
  fflush(stdout);

	t_start = gettime();
	
	// reconfigure hardware slot
  switch(g_arguments.reconf_mode) {
    case RECONF_LINUX:
      ret = linux_icap_load(slot, thread_id); // DOES NOT YET ACCEPT the second slot
      break;
    case RECONF_SW:
      ret = sw_icap_load(slot, thread_id);
      break;
    case RECONF_HW:
      ret = hw_icap_load(slot, thread_id);
      //icap_write(pr_bit[slot][thread_id].block, pr_bit[slot][thread_id].length * 4);
      // TODO: DAFUQ???
      //bitstream_restore(&pr_bit[slot][thread_id]);
      break;
    default:
      break;
  }


	t_stop = gettime();
	t_check = calc_timediff_us(t_start, t_stop);

  printf("Reconfiguration done in %lu us, resetting hardware thread\n", t_check);

	// reset hardware thread
  reconos_slot_reset(slot,0);

	return ret;
}


void segfault_sigaction(int signal, siginfo_t *si, void *arg)
{
  perror("segfault\n");
  printf("Caught segfault at address %p\n", si->si_addr);
  exit(0);
}

void sigill_sigaction(int signal, siginfo_t *si, void *arg)
{
  perror("sigill\n");
  printf("Caught sigill at address %p\n", si->si_addr);
  exit(0);
}

// MAIN ////////////////////////////////////////////////////////////////////
int main(int argc, char *argv[])
{
	int i, cnt=1;

  // TODO: REMOVE
  // catch segfaults
  struct sigaction sa;

  memset(&sa, 0, sizeof(struct sigaction));
  sigemptyset(&sa.sa_mask);
  sa.sa_sigaction = segfault_sigaction;
  sa.sa_flags   = SA_SIGINFO;

  sigaction(SIGSEGV, &sa, NULL);

  // catch SIGILLs
  struct sigaction sigill;

  memset(&sigill, 0, sizeof(struct sigaction));
  sigemptyset(&sigill.sa_mask);
  sigill.sa_sigaction = sigill_sigaction;
  sigill.sa_flags = SA_ONSTACK | SA_RESTART | SA_SIGINFO;

  sigaction(SIGILL, &sigill, NULL);


	printf( "-------------------------------------------------------\n"
		    "ICAP DEMONSTRATOR\n"
		    "(" __FILE__ ")\n"
		    "Compiled on " __DATE__ ", " __TIME__ ".\n"
		    "-------------------------------------------------------\n\n" );

  //----------------------------------------------------------------------------
  // command line parsing
  //----------------------------------------------------------------------------
  cmd_parsing(argc, argv, &g_arguments);
     



	printf("[icap] Initialize ReconOS.\n");
	reconos_init_autodetect();

	printf("[icap] Creating delegate threads.\n\n");
	for (i=0; i<NUM_SLOTS; i++){
		// mbox init
		mbox_init(&mb_in[i],  10);
    mbox_init(&mb_out[i], 10);
		// define resources
		res[i][0].type = RECONOS_TYPE_MBOX;
		res[i][0].ptr  = &mb_in[i];	  	
    res[i][1].type = RECONOS_TYPE_MBOX;
		res[i][1].ptr  = &mb_out[i];
		// start delegate threads
		reconos_hwt_setresources(&hwt[i],res[i],2);
		reconos_hwt_create(&hwt[i],i,NULL);
	}


  // cache partial bitstreams in memory
  bitstream_open("partial_bitstreams/partial_add.bin", &pr_bit[HWT_DPR][ADD]);
  bitstream_open("partial_bitstreams/partial_sub.bin", &pr_bit[HWT_DPR][SUB]);
  bitstream_open("partial_bitstreams/partial_add2.bin", &pr_bit[HWT_DPR2][ADD]);
  bitstream_open("partial_bitstreams/partial_sub2.bin", &pr_bit[HWT_DPR2][SUB]);

  // print current register values
  prblock_get(HWT_DPR, 0);
  prblock_get(HWT_DPR, 1);
  prblock_get(HWT_DPR, 2);
  prblock_get(HWT_DPR, 3);

  prblock_get(HWT_DPR2, 0);
  prblock_get(HWT_DPR2, 1);
  prblock_get(HWT_DPR2, 2);
  prblock_get(HWT_DPR2, 3);

  // what configuration mode are we using?
  switch(g_arguments.reconf_mode) {
    case RECONF_LINUX:
      printf("Using linux reconfiguration mode\n");
      break;
    case RECONF_SW:
      printf("Using software reconfiguration mode\n");
      break;
    case RECONF_HW:
      printf("Using hw reconfiguration mode\n");
      break;
    case RECONF_NULL:
      printf("Using null reconfiguration mode\n");
      break;
  }

  if(g_arguments.mode == MODE_WRITE) {
    while(1) {
      // reconfigure partial hw slot and check thread
      printf("[icap] Test no. %03d\n",cnt);

      reconfigure_prblock(HWT_DPR, ADD);
      test_prblock(HWT_DPR, ADD);


      reconfigure_prblock(HWT_DPR, SUB);
      test_prblock(HWT_DPR, SUB);


      // stop after n reconfigurations
      if(cnt == g_arguments.max_cnt)
        break;

      sleep(1); 
      cnt++;
    }
  } else if(g_arguments.mode == MODE_WRITE_ADD) {
    reconfigure_prblock(HWT_DPR, ADD);
    test_prblock(HWT_DPR, ADD);

    reconfigure_prblock(HWT_DPR2, ADD);
    test_prblock(HWT_DPR2, ADD);

  } else if(g_arguments.mode == MODE_WRITE_SUB) {
    reconfigure_prblock(HWT_DPR, SUB);
    test_prblock(HWT_DPR, SUB);

    reconfigure_prblock(HWT_DPR2, SUB);
    test_prblock(HWT_DPR2, SUB);

  } else if(g_arguments.mode == MODE_CAPTURE) {
    printf("Performing gcapture\n");
    hw_icap_gcapture();
  } else if(g_arguments.mode == MODE_RESTORE) {
    hw_icap_grestore();
  } else if(g_arguments.mode == MODE_TEST) {
    //--------------------------------------------------------------------------
    // Load RM, set some values, capture it
    // Then set different values, load different RM
    // Finally restore original RM, check if values are identical
    //--------------------------------------------------------------------------
    int slot = g_arguments.slot;

    // ensure that we are in a valid state first
    reconfigure_prblock(slot, ADD);
    test_prblock(slot, ADD);
    prblock_get(slot, 3);

    // set values that we want to capture
    prblock_set(slot, 3, 0x11223344);
    prblock_get(slot, 3);

    prblock_mem_set(slot, 0xAABBCCDD);


    // capture bitstream
    struct pr_bitstream_t test_bit;

    bitstream_capture(&pr_bit[slot][ADD], &test_bit);

    printf("Capturing current state completed\n");
    fflush(stdout);

    bitstream_save("partial_bitstreams/test.bin", &test_bit);

    // set it to a different value (just because)
    prblock_set(slot, 3, 0x00DD0000);
    test_prblock(slot, ADD);

    printf("Last check before reconfiguration\n");
    fflush(stdout);

    prblock_mem_set(slot, 0x01010101);
    prblock_mem_get(slot, 0x01010101);

    printf("Memory access done\n");
    fflush(stdout);
    prblock_get(slot, 3);

    printf("Configure sub module\n");
    fflush(stdout);

    // configure different module to erase all traces of the former
    reconfigure_prblock(slot, SUB);
    test_prblock(slot, SUB);

    printf("Sending THREAD_EXIT_CMD\n");
    fflush(stdout);

    // restore captured module
    // send thread exit command
    mbox_put(&mb_in[slot],THREAD_EXIT_CMD);
    usleep(100);
    reconos_slot_reset(slot, 1);

    //sleep(1);
    printf("Performing restore now...\n");
    fflush(stdout);

    bitstream_restore(&test_bit);

    printf("Restore done\n");
    fflush(stdout);

    // reset hardware thread
    reconos_slot_reset(slot, 0);

    //sleep(1);

    printf("reset done\n");
    fflush(stdout);

    prblock_mem_get(slot, 0xAABBCCDD);
    test_prblock(slot, ADD);

    //sleep(1);

    printf("test done\n");
    fflush(stdout);
    prblock_get(slot, 3);
  } else if(g_arguments.mode == MODE_READ) {
    printf("Readback mode, reading %d words from 0x%08X\n", g_arguments.read_words, g_arguments.read_far);

    uint32_t* mem = (uint32_t*) malloc(g_arguments.read_words * sizeof(uint32_t));
    if(mem == NULL) {
      printf("Could not allocate memory\n");
      return EXIT_FAILURE;
    }

    hw_icap_read_frame(g_arguments.read_far, g_arguments.read_words, mem);

    unsigned int i;
    for(i = 0; i < g_arguments.read_words; i++) {
      printf("%08X\n", mem[i]);
    }

  } else if(g_arguments.mode == MODE_SWITCH_BOT) {
    icap_switch_bot();
  } else if(g_arguments.mode == MODE_TEST2) {
    int slot = g_arguments.slot;

    struct pr_bitstream_t test_bit;

    reconfigure_prblock(slot, ADD);
    prblock_mem_set(slot, 0xFFFFFFFF);
    bitstream_capture(&pr_bit[slot][ADD], &test_bit);
    bitstream_save("partial_bitstreams/test.bin", &test_bit);
    prblock_mem_set(slot, 0xABCDABCD);
  } else if(g_arguments.mode == MODE_TEST3) {
    int slot = g_arguments.slot;

    struct pr_bitstream_t test_bit;
    bitstream_open("partial_bitstreams/test.bin", &test_bit);

    hw_icap_write(test_bit.block, test_bit.length * 4);
    prblock_mem_get(slot, 0xFFFFFFFF);
  }

  printf("Exiting now\n");

  // If we use return 0 instead of exit(0) we're getting segmentation faults. I know this makes no sense, but this is what I observed...?
  exit(0);
	return 0;
}

