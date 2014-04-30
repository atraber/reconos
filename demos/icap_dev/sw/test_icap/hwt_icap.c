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

// loads bitstream into ICAP
// Returns 1 if successfull, 0 otherwise
int sw_icap_load(int thread_id)
{
  int retval = 0;

  FILE* fp = fopen("/dev/icap0", "w");
  if(fp == NULL) {
    printf("Could not open icap\n");

    goto FAIL;
  }

  // write whole file in one command
  if( fwrite(pr_bit[thread_id].block, sizeof(uint32_t), pr_bit[thread_id].length, fp) != pr_bit[thread_id].length) {
    printf("Something went wrong while writing to ICAP\n");

    goto FAIL;
  }

  retval = 1;

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

// size must be in words
int hw_icap_read(uint32_t far, uint32_t size, uint32_t* dst)
{
  // account for the padframe and dummy words
  size = size + 82;

  g_icap_read_cmd[21] = far;
  g_icap_read_cmd[23] = (size) | 0x48000000;


  printf("Writing to ICAP\n");
  hw_icap_write(g_icap_read_cmd, sizeof g_icap_read_cmd);

  // read
  uint32_t* mem = (uint32_t*)malloc(size * sizeof(uint32_t));
  if(mem == NULL) {
    printf("Could not allocate buffer\n");
    return 1;
  }

  memset(mem, 0xAB, size * sizeof(uint32_t));

  // AAARGH FUU ZOMFG RAGE!!!!
  // we need to flush the cache here as otherwise we get a part of old data and a part of new data
  reconos_cache_flush();

  printf("Reading %lu bytes from ICAP to address %X\n", size * sizeof(uint32_t), (unsigned int)mem);
  hw_icap_write(mem, (size * sizeof(uint32_t)) | 0x00000001);

  printf("Finishing ICAP\n");
  hw_icap_write(g_icap_read_cmd2, sizeof g_icap_read_cmd2);

  if(dst == NULL) {
    unsigned int i;
    // the first 82 words are rubish, because they are from the pad frame and a dummy word
    for(i = 82; i < size; i++) {
      printf("%08X\n", mem[i]);
    }
  } else {
    memcpy(dst, mem + 82, (size-82) * 4);
  }

  free(mem);

  return 0;
}

uint32_t g_icap_read_reg[] = {0xFFFFFFFF,
                              0x000000BB,
                              0x11220044,
                              0xFFFFFFFF,
                              0xAA995566, // sync
                              0x20000000, // noop
                              0x20000000, // noop
                              0x2800E001, // read from STAT register
                              0x20000000, // noop
                              0x20000000};// noop

uint32_t g_icap_read_reg2[] = {0x30008001, // write to cmd
                               0x0000000D, // DESYNC
                               0x20000000, // noop
                               0x20000000};// noop


// works!
int hw_icap_read_reg(uint8_t reg) {
  // prepare command sequence
  g_icap_read_reg[7] = 0x28000101 | ((reg & 0x1F) << 13);


  printf("Writing to ICAP\n");
  hw_icap_write(g_icap_read_reg, sizeof g_icap_read_reg);

  // read
  uint32_t mem[1];
  mem[0] = 0x00;
  reconos_cache_flush();

  printf("Reading from ICAP\n");
  hw_icap_write(mem, ((1) * 4) | 0x00000001);

  printf("Finishing ICAP\n");
  hw_icap_write(g_icap_read_reg2, sizeof g_icap_read_reg2);


  unsigned int i;
  for(i = 0; i < 1; i++) {
    printf("%08X\n", mem[i]);
  }

  return 0;
}

uint32_t g_icap_gcapture[] = {0xFFFFFFFF,
                              0x000000BB,
                              0x11220044,
                              0xFFFFFFFF,
                              0xAA995566, // sync
                              0x20000000, // noop
                              0x20000000, // noop
                              0x30008001, // write to cmd
                              0x0000000C, // gcapture
                              0x20000000, // noop
                              0x30002001, // write to FAR
                              0x00000000, // FAR address
                              0x20000000, // noop
                              0x20000000, // noop
                              0x30008001, // write to cmd
                              0x0000000D, // DESYNC
                              0x20000000, // noop
                              0x20000000};// noop

int hw_icap_gcapture() {
  printf("Performing gcapture\n");
  hw_icap_write(g_icap_gcapture, sizeof g_icap_gcapture);

  return 0;
}

// uint32_t g_icap_grestore[] = {0xFFFFFFFF,
//                               0x000000BB,
//                               0x11220044,
//                               0xFFFFFFFF,
//                               0xAA995566, // sync
//                               0x20000000, // noop
//                               0x20000000, // noop
//                               0x30008001, // write to cmd
//                               0x0000000A, // grestore
//                               0x20000000, // noop
//                               0x30002001, // write to FAR
//                               0x00000000, // FAR address
//                               0x20000000, // noop
//                               0x20000000, // noop
//                               0x30008001, // write to cmd
//                               0x0000000D, // DESYNC
//                               0x20000000, // noop
//                               0x20000000};// noop
uint32_t g_icap_grestore[] = {0xFFFFFFFF,
                              0x000000BB,
                              0x11220044,
                              0xFFFFFFFF,
                              0xAA995566, // sync
                              0x20000000, // noop
                              0x20000000, // noop
                              0x3000C001, // Type 1 packet, Write, MASK reg 1 packets follow
                              0x00000400, //  belongs to previous packet, 0 packets follow   
                              0x3000A001, // Type 1 packet, Write, CTL0 reg 1 packets follow
                              0x00000400, //  belongs to previous packet, 0 packets follow   
                              0x30008001, // Type 1 packet, Write, CMD reg 1 packets follow
                              0x00000000, // NULL belongs to previous packet, 0 packets follow   
                              0x30002001, // Type 1 packet, Write, FAR reg 1 packets follow
                              0x00000000, //  belongs to previous packet, 0 packets follow   
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x30008001, //Type 1 packet, Write, CMD reg 1 packets follow
                              0x0000000B, //SHUTDOWN belongs to previous packet, 0 packets follow
                              0x20000000, //Type 1 packet, NOOP 0 packets follow
                              0x20000000, //Type 1 packet, NOOP 0 packets follow
                              0x20000000, //Type 1 packet, NOOP 0 packets follow
                              0x20000000, //Type 1 packet, NOOP 0 packets follow
                              0x20000000, //Type 1 packet, NOOP 0 packets follow
                              0x30008001, //Type 1 packet, Write, CMD reg 1 packets follow
                              0x00000000, //NULL belongs to previous packet, 0 packets follow
                              0x30002001, //Type 1 packet, Write, FAR reg 1 packets follow
                              0x00000000, // belongs to previous packet, 0 packets follow
                              0x30008001, // Type 1 packet, Write, CMD reg 1 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x0000000A, // GRESTORE belongs to previous packet, 0 packets follow   
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x3000C001, // Type 1 packet, Write, MASK reg 1 packets follow
                              0x00001000, //  belongs to previous packet, 0 packets follow   
                              0x30030001, // Type 1 packet, Write, unknown reg 1 packets follow
                              0x00000000, //  belongs to previous packet, 0 packets follow   
                              0x30008001, // Type 1 packet, Write, CMD reg 1 packets follow
                              0x00000003, // DGHIGH belongs to previous packet, 0 packets follow   
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x30008001, // Type 1 packet, Write, CMD reg 1 packets follow
                              0x00000005, // START belongs to previous packet, 0 packets follow   
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x30002001, // Type 1 packet, Write, FAR reg 1 packets follow
                              0x00EF8000, //  belongs to previous packet, 0 packets follow   
                              0x30008001, // Type 1 packet, Write, CMD reg 1 packets follow
                              0x0000000D, // DESYNC belongs to previous packet, 0 packets follow   DESYNCH
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000, // Type 1 packet, NOOP 0 packets follow
                              0x20000000};// Type 1 packet, NOOP 0 packets follow


int hw_icap_grestore() {
  printf("Writing to ICAP\n");
  hw_icap_write(g_icap_grestore, sizeof g_icap_grestore);

  return 0;
}

int hw_icap_gsr() {
  printf("Performing GSR\n");
  hw_icap_write(0x0, 0x2);

  return 0;
}

// addr points to an array in memory, size is in bytes
int hw_icap_write_block(uint32_t far, uint32_t* addr, unsigned int size)
{
  printf("hw_icap_write_block: TODO\n");
	int ret = 0;
/*
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

*/
	return ret;
}
