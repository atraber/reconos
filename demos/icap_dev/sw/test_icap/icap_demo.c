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

int test_icapblock(void)
{
	unsigned int ret;
	mbox_put(&mb_in[HWT_ICAP],1);
	mbox_put(&mb_in[HWT_ICAP],2);
	ret = mbox_get(&mb_out[HWT_ICAP]);
	printf("  ret=%d\n",ret);
	return 0;
}

int g_debug_hw_sw = 1;

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
	if (thread_id == ADD) {
    switch(g_reconf_mode) {
      case RECONF_LINUX:
        ret = system("cat partial_bitstreams/partial_add.bit > /dev/icap0");
        break;
      case RECONF_SW:
        ret = sw_icap_load(thread_id);
        break;
      case RECONF_HW:
          printf("NOT YET IMPLEMENTED\n");
        break;
    }

    configured = thread_id;
  } else if (thread_id==SUB) {
    switch(g_reconf_mode) {
      case RECONF_LINUX:
        ret = system("cat partial_bitstreams/partial_sub.bit > /dev/icap0");
        break;
      case RECONF_SW:
        ret = sw_icap_load(thread_id);
        break;
      case RECONF_HW:
          printf("NOT YET IMPLEMENTED\n");
        break;
    }

    configured = thread_id;
  }

	t_stop = gettime();
	t_check = calc_timediff_ms(t_start, t_stop);

  printf("Reconfiguration done in %lu, reseting hardware thread\n", t_check);

	// reset hardware thread and start new delegate
	reconos_hwt_setresources(&hwt[HWT_DPR],res[HWT_DPR],2);
	reconos_hwt_create(&hwt[HWT_DPR],HWT_DPR,NULL);

	return ret;
}

// MAIN ////////////////////////////////////////////////////////////////////
int main(int argc, char *argv[])
{
	int i, ret,cnt=1;
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
  if(argc >= 2) {
    if(strcmp(argv[1], "-sw") == 0)
      g_reconf_mode = RECONF_SW;
    else if(strcmp(argv[1], "-hw") == 0)
      g_reconf_mode = RECONF_HW;
    else if(strcmp(argv[1], "-linux") == 0)
      g_reconf_mode = RECONF_LINUX;
  }

	while(1) {
		// reconfigure partial hw slot and check thread
		printf("[icap] Test no. %03d\n",cnt);

		ret = reconfigure_prblock(ADD);
		ret = test_prblock(ADD);

		if (ret) printf("  # ADD: passed\n"); else printf("  # ADD: failed\n");

		ret = reconfigure_prblock(SUB);
		ret = test_prblock(SUB);

		if (ret) printf("  # SUB: passed\n"); else printf("  # SUB: failed\n");
		sleep(1); 
		cnt++;
	}
	return 0;
}

