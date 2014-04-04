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

// hw threads
#define NUM_SLOTS 2
#define HWT_ICAP  0
#define HWT_DPR   1

#define ADD 0
#define SUB 1

#define THREAD_EXIT_CMD 0xFFFFFFFF

#define RECONF_LINUX 0
#define RECONF_SW    1
#define RECONF_HW    2
#define RECONF_NULL  3

unsigned int g_reconf_mode = RECONF_LINUX;

struct reconos_resource res[NUM_SLOTS][2];
struct reconos_hwt hwt[NUM_SLOTS];
struct mbox mb_in[NUM_SLOTS];
struct mbox mb_out[NUM_SLOTS];

unsigned int configured = ADD;

struct pr_bitstream {
  uint32_t* block;
  unsigned int length; // in 32 bit words
};

struct pr_bitstream pr_bit[2];

// preload bitstream and save it in memory
// Returns 1 if successfull, 0 otherwise
int cache_bitstream(int thread_id, const char* path)
{
  int retval = 1;

  FILE* fp = fopen(path, "r");
  if(fp == NULL) {
    printf("Could not open file %s\n", path);

    retval = 0;
    goto FAIL;
  }

  // determine file size
  fseek(fp, 0L, SEEK_END);
  pr_bit[thread_id].length = ftell(fp);

  fseek(fp, 0L, SEEK_SET);

  if((pr_bit[thread_id].length & 0x3) != 0) {
    printf("File size is not a multiple of 4 bytes\n");

    retval = 0;
    goto FAIL;
  }

  // convert file size from bytes to 32 bit words
  pr_bit[thread_id].length = pr_bit[thread_id].length / 4;

  // allocate memory for file
  pr_bit[thread_id].block = (uint32_t*)malloc(pr_bit[thread_id].length * sizeof(uint32_t));
  if(pr_bit[thread_id].block == NULL) {
    printf("Could not allocate memory\n");

    retval = 0;
    goto FAIL;
  }

  // read whole file in one command
  if( fread(pr_bit[thread_id].block, sizeof(uint32_t), pr_bit[thread_id].length, fp) != pr_bit[thread_id].length) {
    printf("Something went wrong while reading from file\n");

    free(pr_bit[thread_id].block);

    retval = 0;
    goto FAIL;
  }

FAIL:
  fclose(fp);

  return retval;
}

// load arbitrary cmd sequence via hardware icap thread
int hw_icap_write(uint32_t* addr, unsigned int size)
{
	int ret;

  // send address of bitfile in main memory to hwt
	mbox_put(&mb_in[HWT_ICAP], (unsigned int)addr);

  // send length of bitfile (in bytes) in main memory to hwt
	mbox_put(&mb_in[HWT_ICAP], size);

  // wait for response from hwt
	ret = mbox_get(&mb_out[HWT_ICAP]);
	printf("hwt_icap returned %X\n", ret);

	return ret;
}

// load arbitrary cmd sequence via software icap
int sw_icap_write(uint32_t* addr, unsigned int size)
{
  int retval = 1;

  FILE* fp = fopen("/dev/icap0", "w");
  if(fp == NULL) {
    printf("Could not open icap\n");

    retval = 0;
    goto FAIL;
  }

  // write whole file in one command
  if( fwrite(addr, sizeof(uint32_t), size/4, fp) != (size / 4)) {
    printf("Something went wrong while writing to ICAP\n");

    retval = 0;
    goto FAIL;
  }

FAIL:
  fclose(fp);

  return retval;
}

// loads bitstream into ICAP
// Returns 1 if successfull, 0 otherwise
int sw_icap_load(int thread_id)
{
  int retval = 1;

  FILE* fp = fopen("/dev/icap0", "w");
  if(fp == NULL) {
    printf("Could not open icap\n");

    retval = 0;
    goto FAIL;
  }

  // write whole file in one command
  if( fwrite(pr_bit[thread_id].block, sizeof(uint32_t), pr_bit[thread_id].length, fp) != pr_bit[thread_id].length) {
    printf("Something went wrong while writing to ICAP\n");

    retval = 0;
    goto FAIL;
  }

FAIL:
  fclose(fp);

  return retval;
}

// load partial bitfile via hardware icap thread
int hw_icap_load(int thread_id)
{
	int ret;

  uint32_t* addr = pr_bit[thread_id].block;
  unsigned int size = (unsigned int)pr_bit[thread_id].length * 4;

  ret = hw_icap_write(addr, size);

	return ret;
}


// untested
uint32_t g_icap_crc_clear[] = {0xFFFFFFFF,
                               0x000000BB,
                               0x11220044,
                               0xFFFFFFFF,
                               0xAA995566,
                               0x20000000,
                               0x30008001,
                               0x00000007,
                               0x20000000,
                               0x30008001,
                               0x0000000D,
                               0x20000000,
                               0x20000000};
// icap switch to bottom, does work!
uint32_t g_icap_switch_bot[] = {0xFFFFFFFF,
                                0x000000BB,
                                0x11220044,
                                0xFFFFFFFF,
                                0xAA995566, // sync
                                0x20000000,
                                0x3000A001, // write to mask
                                0x40000000,
                                0x20000000,
                                0x3000C001, // write to ctl0
                                0x40000000,
                                0x20000000,
                                0x30008001,
                                0x0000000D, // desync
                                0x20000000,
                                0x20000000};

// does not work?
// icap switch to top
uint32_t g_icap_switch_top[] = {0xFFFFFFFF,
                                0x000000BB,
                                0x11220044,
                                0xFFFFFFFF,
                                0xAA995566, // sync
                                0x20000000,
                                0x3000A001, // write to mask
                                0x40000000,
                                0x20000000,
                                0x3000C001, // write to ctl0
                                0x00000000,
                                0x20000000,
                                0x30008001,
                                0x0000000D, // desync
                                0x20000000,
                                0x20000000};

int linux_icap_load(int thread_id)
{
  int ret = -2;

  if(thread_id == ADD)
    ret = system("cat partial_bitstreams/partial_add.bit > /dev/icap0");
  else if(thread_id == SUB)
    ret = system("cat partial_bitstreams/partial_sub.bit > /dev/icap0");

  return ret;
}

int test_prblock(int thread_id)
{
	unsigned int ret, val=0x60003;
	mbox_put(&mb_in[HWT_DPR],val);
	ret = mbox_get(&mb_out[HWT_DPR]);
	printf("  calc - input=%x, output=%d\n",val,ret);
	if (thread_id==ADD && ret==(val/0x10000)+(val%0x10000)) return 1;
	if (thread_id==SUB && ret==(val/0x10000)-(val%0x10000)) return 1;
	return 0;
}

int reconfigure_prblock(int thread_id)
{
	timing_t t_start, t_stop;
  ms_t t_check;

	int ret = -2;

	if (thread_id==configured) return 0;

	// send thread exit command
	mbox_put(&mb_in[HWT_DPR],THREAD_EXIT_CMD);

  sleep(1);

  printf("Starting reconfiguration\n");

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
	t_check = calc_timediff_ms(t_start, t_stop);

  printf("Reconfiguration done in %lu ms, reseting hardware thread\n", t_check);

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
      if(i + 1 < argc)
        max_cnt = atoi(argv[i + 1]);
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

//  sw_icap_write(g_icap_switch_top, sizeof g_icap_switch_top);
//  return 0;

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
	return 0;
}

