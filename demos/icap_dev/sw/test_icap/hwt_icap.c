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

#include "icap_demo.h"


struct pr_bitstream {
  uint32_t* block;
  unsigned int length; // in 32 bit words
};

struct pr_bitstream pr_bit[2];


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
  if(ret == 0x1337)
    printf("hwt_icap returned SUCCESS, code %X\n", ret);
  else
    printf("hwt_icap returned ERROR, code %X\n", ret);

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



// untested
uint32_t g_icap_crc_clear[] = {0xFFFFFFFF, // Dummy Word
                               0x000000BB, // Bus Width Sync Word
                               0x11220044, // Bus Width Detect
                               0xFFFFFFFF, // Dummy Word
                               0xAA995566, // Sync Word
                               0x20000000, // NOOP
                               0x30008001, // Type 1 write to CMD
                               0x00000007, // RCRC
                               0x20000000, // NOOP
                               0x30008001, // Type 1 write to CMD
                               0x0000000D, // DESYNC
                               0x20000000, // NOOP
                               0x20000000}; // NOOP
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


// switches to bottom icap using hwt_icap
void hwt_icap_switch_bot() {
  hw_icap_write(g_icap_switch_bot, sizeof g_icap_switch_bot);
}

// switches to bottom icap using hwt_icap
void hwt_icap_clear_crc() {
  hw_icap_write(g_icap_crc_clear, sizeof g_icap_crc_clear);
}


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

// load partial bitfile via hardware icap thread
int hw_icap_load(int thread_id)
{
	int ret;

  uint32_t* addr = pr_bit[thread_id].block;
  unsigned int size = (unsigned int)pr_bit[thread_id].length * 4;

  ret = hw_icap_write(addr, size);

	return ret;
}

int linux_icap_load(int thread_id)
{
  int ret = -2;

  if(thread_id == ADD)
    ret = system("cat partial_bitstreams/partial_add.bit > /dev/icap0");
  else if(thread_id == SUB)
    ret = system("cat partial_bitstreams/partial_sub.bit > /dev/icap0");

  return ret;
}

