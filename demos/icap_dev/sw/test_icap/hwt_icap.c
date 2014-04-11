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
// size must be in bytes
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
  if(fp != NULL)
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
uint32_t g_icap_switch_bot[] = {0xFFFFFFFF, // Dummy word
                                0x000000BB, // Bus Width Sync Word
                                0x11220044, // Bus Width Detect
                                0xFFFFFFFF, // Dummy Word
                                0xAA995566, // SYNC
                                0x20000000, // NOOP
                                0x3000A001, // write to mask
                                0x40000000, // icap control
                                0x20000000, // NOOP
                                0x3000C001, // write to ctl0
                                0x40000000, // change icap
                                0x20000000, // NOOP
                                0x30008001, // write to cmd
                                0x0000000D, // DESYNC
                                0x20000000, // NOOP
                                0x20000000}; // NOOP

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
void icap_switch_bot() {
  hw_icap_write(g_icap_switch_bot, sizeof g_icap_switch_bot);
}

// switches to bottom icap using hwt_icap
void icap_switch_top() {
  sw_icap_write(g_icap_switch_top, sizeof g_icap_switch_top);
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


uint32_t g_icap_read_cmd[] = {0xFFFFFFFF,
                              0x000000BB,
                              0x11220044,
                              0xFFFFFFFF,
                              0xAA995566, // sync
                              0x20000000, // noop
                              0x30008001, // write to cmd
                              0x0000000B, // SHUTDOWN
                              0x20000000, // noop
                              0x30008001, // write to cmd
                              0x00000007, // RCRC
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x30008001, // write to cmd
                              0x00000004, // RCFG
                              0x20000000, // noop
                              0x30002001, // write to FAR
                              0x00008A80, // FAR address
                              0x28006000, // type 1 read 0 words from FDRO
                              0x48000080, // type 2 read 128 words from FDRO
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000, // noop
                              0x20000000};// noop

uint32_t g_icap_read_cmd2[] = {0x20000000, // noop
                               0x30008001, // write to cmd
                               0x00000005, // START
                               0x20000000, // noop
                               0x30008001, // write to cmd
                               0x00000007, // RCRC
                               0x20000000, // noop
                               0x30008001, // write to cmd
                               0x0000000D, // DESYNC
                               0x20000000, // noop
                               0x20000000};// noop

#define get_bit(in, bit)    ((in & (1 << bit)) >> bit)
uint32_t bitswap(uint32_t in) {
  uint32_t out = 0;

  out = (get_bit(in, 24) << 31) |
        (get_bit(in, 25) << 30) |
        (get_bit(in, 26) << 29) |
        (get_bit(in, 27) << 28) |
        (get_bit(in, 28) << 27) |
        (get_bit(in, 29) << 26) |
        (get_bit(in, 30) << 25) |
        (get_bit(in, 31) << 24) |
        (get_bit(in, 16) << 23) |
        (get_bit(in, 17) << 22) |
        (get_bit(in, 18) << 21) |
        (get_bit(in, 19) << 20) |
        (get_bit(in, 20) << 19) |
        (get_bit(in, 21) << 18) |
        (get_bit(in, 22) << 17) |
        (get_bit(in, 23) << 16) |
        (get_bit(in,  8) << 15) |
        (get_bit(in,  9) << 14) |
        (get_bit(in, 10) << 13) |
        (get_bit(in, 11) << 12) |
        (get_bit(in, 12) << 11) |
        (get_bit(in, 13) << 10) |
        (get_bit(in, 14) <<  9) |
        (get_bit(in, 15) <<  8) |
        (get_bit(in,  0) <<  7) |
        (get_bit(in,  1) <<  6) |
        (get_bit(in,  2) <<  5) |
        (get_bit(in,  3) <<  4) |
        (get_bit(in,  4) <<  3) |
        (get_bit(in,  5) <<  2) |
        (get_bit(in,  6) <<  1) |
        (get_bit(in,  7) <<  0);

        return out;
}

// size must be in words
int hw_icap_read(uint32_t far, uint32_t size) {
  g_icap_read_cmd[21] = far;
  g_icap_read_cmd[23] = size | 0x48000000;


  printf("Writing to ICAP\n");
  hw_icap_write(g_icap_read_cmd, sizeof g_icap_read_cmd);

  // read
  uint32_t* mem = (uint32_t*)malloc(size * sizeof(uint32_t));

  if(mem == NULL) {
    printf("Could not allocate buffer\n");
    return 1;
  }

  printf("Reading %lu bytes from ICAP\n", size * sizeof(uint32_t));
  hw_icap_write(mem, (size * sizeof(uint32_t)) | 0x00000001);

  printf("Finishing ICAP\n");
  hw_icap_write(g_icap_read_cmd2, sizeof g_icap_read_cmd2);


  unsigned int i;
  for(i = 0; i < size; i++) {
    if(i == 81 + 1) { 
      // the first 81 words are probably rubish, because they are from the pad frame
      printf("This was the pad frame + dummy words, now real data should be available\n");
    }

    printf("%08X\n", mem[i]);
  }

  free(mem);

  return 0;
}

uint32_t g_icap_read_stat[] = {0xFFFFFFFF,
                              0x000000BB,
                              0x11220044,
                              0xFFFFFFFF,
                              0xAA995566, // sync
                              0x20000000, // noop
                              0x20000000, // noop
                              0x2800E001, // read from STAT register
                              0x20000000, // noop
                              0x20000000};// noop

uint32_t g_icap_read_stat2[] = {0x30008001, // write to cmd
                               0x0000000D, // DESYNC
                               0x20000000, // noop
                               0x20000000};// noop


int hw_icap_read_stat() {
  printf("Writing to ICAP\n");
  hw_icap_write(g_icap_read_stat, sizeof g_icap_read_stat);

  // read
  uint32_t mem[1];
  printf("Reading from ICAP\n");
  hw_icap_write(mem, (4) | 0x00000001);

  printf("Finishing ICAP\n");
  hw_icap_write(g_icap_read_stat2, sizeof g_icap_read_stat2);


  unsigned int i;
  for(i = 0; i < 1; i++) {
    printf("%X\n", bitswap(mem[i]));
  }

  return 0;
}
