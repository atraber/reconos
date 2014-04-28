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

// ReconOS
#include "reconos.h"
#include "mbox.h"

#include "timing.h"

#include "icap_demo.h"

#define RECONF_LINUX 0
#define RECONF_SW    1
#define RECONF_HW    2
#define RECONF_NULL  3

unsigned int g_reconf_mode = RECONF_HW;

#define MODE_WRITE      0
#define MODE_READ       1
#define MODE_WRITE_ADD  2
#define MODE_WRITE_SUB  3
#define MODE_CAPTURE    4
#define MODE_TEST    5

unsigned int g_mode = MODE_WRITE;

struct reconos_resource res[NUM_SLOTS][2];
struct reconos_hwt hwt[NUM_SLOTS];
struct mbox mb_in[NUM_SLOTS];
struct mbox mb_out[NUM_SLOTS];

unsigned int configured = 0xFF; // invalid value...


int test_prblock(int thread_id)
{
  unsigned int ret, counter;
  // set register 0
	mbox_put(&mb_in[HWT_DPR], 0x00000000);
	mbox_put(&mb_in[HWT_DPR], 0x01003344);

  // set register 1
	mbox_put(&mb_in[HWT_DPR], 0x00000001);
	mbox_put(&mb_in[HWT_DPR], 0x01001122);

  // get result from register 2
	mbox_put(&mb_in[HWT_DPR], 0x80000002);
	ret = mbox_get(&mb_out[HWT_DPR]);

  printf("Result is %X\n", ret);

  // get counter value from register 3
	mbox_put(&mb_in[HWT_DPR], 0x80000003);
	counter = mbox_get(&mb_out[HWT_DPR]);
  
  printf("Counter value is %u\n", counter);
  

	if (thread_id==ADD && ret==(0x01003344)+(0x01001122)) return 1;
	if (thread_id==SUB && ret==(0x01003344)-(0x01001122)) return 1;
	return 0;
}

int prblock_set(unsigned int reg, uint32_t value)
{
	mbox_put(&mb_in[HWT_DPR], reg);
	mbox_put(&mb_in[HWT_DPR], value);

	return 0;
}

int prblock_get(unsigned int reg)
{
  unsigned int ret;

	mbox_put(&mb_in[HWT_DPR], reg | 0x80000000);

	ret = mbox_get(&mb_out[HWT_DPR]);

  printf("Register %X has value %X\n", reg, ret);

	return ret;
}

int reconfigure_prblock(int thread_id)
{
	timing_t t_start, t_stop;
  us_t t_check;

	int ret = -2;

	if (thread_id==configured) return 0;

	// send thread exit command
	mbox_put(&mb_in[HWT_DPR],THREAD_EXIT_CMD);

  sleep(1);

  printf("Starting reconfiguration\n");
  fflush(stdout);

	t_start = gettime();
	
	// reconfigure hardware slot
  switch(g_reconf_mode) {
    case RECONF_LINUX:
      ret = linux_icap_load(thread_id);
      break;
    case RECONF_SW:
      ret = sw_icap_load(thread_id);
      break;
    case RECONF_HW:
      ret = hw_icap_load(thread_id);
      break;
    default:
      break;
  }

  configured = thread_id;

	t_stop = gettime();
	t_check = calc_timediff_us(t_start, t_stop);

  printf("Reconfiguration done in %lu us, reseting hardware thread\n", t_check);

	// reset hardware thread and start new delegate
	reconos_hwt_setresources(&hwt[HWT_DPR],res[HWT_DPR],2);
	reconos_hwt_create(&hwt[HWT_DPR],HWT_DPR,NULL);

	return ret;
}

// MAIN ////////////////////////////////////////////////////////////////////
int main(int argc, char *argv[])
{
	int i, ret,cnt=1;
  int max_cnt = 10;
  unsigned int read_far = 0x00208100;//0x00008A80;
  unsigned int read_words = 1;

	printf( "-------------------------------------------------------\n"
		    "ICAP DEMONSTRATOR\n"
		    "(" __FILE__ ")\n"
		    "Compiled on " __DATE__ ", " __TIME__ ".\n"
		    "-------------------------------------------------------\n\n" );

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
  cache_bitstream(ADD, "partial_bitstreams/partial_add.bit");
  cache_bitstream(SUB, "partial_bitstreams/partial_sub.bit");

  // print current register values
  prblock_get(0);
  prblock_get(1);
  prblock_get(2);
  prblock_get(3);

  // parse command line arguments
  for(i = 1; i < argc; i++) {
    if(strcmp(argv[i], "-sw") == 0)
      g_reconf_mode = RECONF_SW;
    else if(strcmp(argv[i], "-hw") == 0)
      g_reconf_mode = RECONF_HW;
    else if(strcmp(argv[i], "-linux") == 0)
      g_reconf_mode = RECONF_LINUX;
    else if(strcmp(argv[i], "-null") == 0)
      g_reconf_mode = RECONF_NULL;
    else if(strcmp(argv[i], "-n") == 0) {
      if(i + 1 < argc) {
        max_cnt = atoi(argv[i + 1]);
        i++; // skip one as we handle it already here
      }
    } else if(strcmp(argv[i], "-r") == 0) {
      g_mode = MODE_READ;

      if(i + 1 < argc) {
        read_words = atoi(argv[i + 1]);
        i++; // skip one as we handle it already here
      }
    } else if(strcmp(argv[i], "-f") == 0) {
      g_mode = MODE_READ;

      if(i + 1 < argc) {
        sscanf(argv[i + 1], "0x%X", &read_far);
        i++; // skip one as we handle it already here
      }
    } else if(strcmp(argv[i], "--add") == 0) {
      g_mode = MODE_WRITE_ADD;
    } else if(strcmp(argv[i], "--sub") == 0) {
      g_mode = MODE_WRITE_SUB;
    } else if(strcmp(argv[i], "--capture") == 0) {
      g_mode = MODE_CAPTURE;
    } else if(strcmp(argv[i], "--test") == 0) {
      g_mode = MODE_TEST;
    }
  }

  // what configuration mode are we using?
  switch(g_reconf_mode) {
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

  if(g_mode == MODE_WRITE) {
    while(1) {
      // reconfigure partial hw slot and check thread
      printf("[icap] Test no. %03d\n",cnt);

      ret = reconfigure_prblock(ADD);
      ret = test_prblock(ADD);

      if (ret) printf("  # ADD: passed\n"); else printf("  # ADD: failed\n");

      ret = reconfigure_prblock(SUB);
      ret = test_prblock(SUB);

      if (ret) printf("  # SUB: passed\n"); else printf("  # SUB: failed\n");


      // stop after n reconfigurations
      if(cnt == max_cnt)
        break;

      sleep(1); 
      cnt++;
    }
  } else if(g_mode == MODE_WRITE_ADD) {
    ret = reconfigure_prblock(ADD);
    ret = test_prblock(ADD);

    if (ret) printf("  # ADD: passed\n"); else printf("  # ADD: failed\n");
  } else if(g_mode == MODE_WRITE_SUB) {
    ret = reconfigure_prblock(SUB);
    ret = test_prblock(SUB);

    if (ret) printf("  # SUB: passed\n"); else printf("  # SUB: failed\n");
  } else if(g_mode == MODE_CAPTURE) {
    prblock_set(3, 0x00000000);
    prblock_get(3);

    printf("Performing gcapture\n");
    hw_icap_gcapture();
    sleep(1);


    // printf("Performing grestore\n");
    // hw_icap_grestore();
    // sleep(1);
    // prblock_get(3);

    printf("Readback mode, reading %d words from 0x%08X\n", read_words, read_far);
    hw_icap_read(read_far, read_words);
/*
    prblock_get(3);
    prblock_set(3, 0x00000001);
    prblock_get(3);

    printf("Performing gcapture\n");
    hw_icap_gcapture();
    sleep(1);

    printf("Readback mode, reading %d words from 0x%08X\n", read_words, read_far);
    hw_icap_read(read_far, read_words);
    */
  } else if(g_mode == MODE_TEST) {
    prblock_set(3, 0x00000000);
    prblock_get(3);

    printf("Performing gcapture\n");
    hw_icap_gcapture();
    sleep(1);


    printf("Performing grestore\n");
    hw_icap_grestore();
    sleep(1);
    prblock_get(3);

    printf("Setting it to different value\n");
    prblock_set(3, 0x00000001);
    prblock_get(3);

    printf("Performing grestore\n");
    hw_icap_grestore();
    sleep(1);
    prblock_get(3);
  } else {
    printf("Readback mode, reading %d words from 0x%08X\n", read_words, read_far);
    hw_icap_read(read_far, read_words);

    //hw_icap_read_reg(0x9);
  }

	return 0;
}

