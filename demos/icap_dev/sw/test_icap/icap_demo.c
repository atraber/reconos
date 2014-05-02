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
#include <argp.h>

// ReconOS
#include "reconos.h"
#include "mbox.h"

#include "timing.h"

#include "icap_demo.h"


#define RECONF_LINUX 0
#define RECONF_SW    1
#define RECONF_HW    2
#define RECONF_NULL  3

#define MODE_WRITE      0
#define MODE_READ       1
#define MODE_WRITE_ADD  2
#define MODE_WRITE_SUB  3
#define MODE_CAPTURE    4
#define MODE_RESTORE    5
#define MODE_TEST       6

struct cmd_arguments_t {
  unsigned int reconf_mode;
  unsigned int mode;
  unsigned int max_cnt;
  unsigned int read_far;
  unsigned int read_words;
};

struct cmd_arguments_t g_arguments;



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

  //printf("Result is %X\n", ret);

  // get counter value from register 3
	mbox_put(&mb_in[HWT_DPR], 0x80000003);
	counter = mbox_get(&mb_out[HWT_DPR]);
  
  switch(thread_id) {
  case ADD:
    if (ret==(0x01003344)+(0x01001122)) {
      printf("  # ADD: passed\n");
    } else {
      printf("  # ADD: failed\n");
    }

    return 1;

  case SUB:
    if (ret==(0x01003344)-(0x01001122)) {
      printf("  # SUB: passed\n");
    } else {
      printf("  # SUB: failed\n");
    }
    return 1;
  }

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
  switch(g_arguments.reconf_mode) {
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

  printf("Reconfiguration done in %lu us, resetting hardware thread\n", t_check);

	// reset hardware thread and start new delegate
	reconos_hwt_setresources(&hwt[HWT_DPR],res[HWT_DPR],2);
	reconos_hwt_create(&hwt[HWT_DPR],HWT_DPR,NULL);

	return ret;
}

/* The options we understand. */
static struct argp_option options[] = {
  {"hw",    2400, 0,     0,  "Use hwt_icap for reconfiguration" },
  {"sw",    2500, 0,     0,  "Use software for reconfiguration" },
  {"linux", 2600, 0,     0,  "Use linux for reconfiguration" },
  {"null",  2700, 0,     0,  "Use nothing for reconfiguration (just test)" },
  {"write", 'w',  "nr",  0,  "Write to ICAP interface and test the slot, do this <nr> times" },
  {"add",   3000, 0,     0,  "Write ADD to ICAP interface and test the slot" },
  {"sub",   3100, 0,     0,  "Write SUB to ICAP interface and test the slot" },
  {"read",  'r',  "nr",  0,
   "Read from ICAP interface and dump its output to console, read <nr> words" },
  {"far",     'f',  "FAR", 0,  "FAR to read from, must be in hex format (0xABCD)" },
  {"capture", 4000, 0,     0,  "Capture current state using GCAPTURE" },
  {"restore", 4100, 0,     0,  "Restore state using GSR" },
  {"test",    't',  0,     0,  "Playground.. can be anything here" },
  { 0 }
};

/* Parse a single option. */
static error_t
parse_opt (int key, char *arg, struct argp_state *state)
{
  /* Get the input argument from argp_parse, which we
     know is a pointer to our arguments structure. */
  struct cmd_arguments_t *arguments = &g_arguments;

  switch (key)
  {
  case 2400:
    arguments->reconf_mode = RECONF_HW;
    break;

  case 2500:
    arguments->reconf_mode = RECONF_SW;
    break;

  case 2600:
    arguments->reconf_mode = RECONF_LINUX;
    break;

  case 2700:
    arguments->reconf_mode = RECONF_NULL;
    break;

  case 'w':
    arguments->mode = MODE_WRITE;
    arguments->max_cnt = atoi(arg);
    break;

  case 3000:
    arguments->mode = MODE_WRITE_ADD;
    break;

  case 3100:
    arguments->mode = MODE_WRITE_SUB;
    break;

  case 4000:
    arguments->mode = MODE_CAPTURE;
    break;

  case 4100:
    arguments->mode = MODE_RESTORE;
    break;

  case 't':
    arguments->mode = MODE_TEST;
    break;

  case 'r':
    arguments->mode = MODE_READ;
    arguments->read_words = atoi(arg);
    break;

  case 'f':
    sscanf(arg, "0x%X", &arguments->read_far);
    break;

  default:
    return ARGP_ERR_UNKNOWN;
  }
  return 0;
}

static struct argp argp = { options, parse_opt, "", "" };

// MAIN ////////////////////////////////////////////////////////////////////
int main(int argc, char *argv[])
{
	int i, ret,cnt=1;

	printf( "-------------------------------------------------------\n"
		    "ICAP DEMONSTRATOR\n"
		    "(" __FILE__ ")\n"
		    "Compiled on " __DATE__ ", " __TIME__ ".\n"
		    "-------------------------------------------------------\n\n" );

  //----------------------------------------------------------------------------
  // command line parsing
  //----------------------------------------------------------------------------
     
  // default values
  g_arguments.reconf_mode = RECONF_HW;
  g_arguments.mode = MODE_WRITE;
  g_arguments.max_cnt = 10;
  g_arguments.read_far = 0x8A80;
  g_arguments.read_words = 1;

  argp_parse (&argp, argc, argv, 0, 0, &g_arguments);
 

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
  bitstream_open("partial_bitstreams/partial_add.bit", &pr_bit[ADD]);
  bitstream_open("partial_bitstreams/partial_sub.bit", &pr_bit[SUB]);

  // print current register values
  prblock_get(0);
  prblock_get(1);
  prblock_get(2);
  prblock_get(3);

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

      reconfigure_prblock(ADD);
      test_prblock(ADD);


      reconfigure_prblock(SUB);
      test_prblock(SUB);


      // stop after n reconfigurations
      if(cnt == g_arguments.max_cnt)
        break;

      sleep(1); 
      cnt++;
    }
  } else if(g_arguments.mode == MODE_WRITE_ADD) {
    ret = reconfigure_prblock(ADD);
    ret = test_prblock(ADD);

  } else if(g_arguments.mode == MODE_WRITE_SUB) {
    ret = reconfigure_prblock(SUB);
    ret = test_prblock(SUB);

  } else if(g_arguments.mode == MODE_CAPTURE) {
    printf("Performing gcapture\n");
    hw_icap_gcapture();
  } else if(g_arguments.mode == MODE_RESTORE) {
    hw_icap_gsr();
  } else if(g_arguments.mode == MODE_TEST) {
    reconfigure_prblock(ADD);
    test_prblock(ADD);
    prblock_get(3);

    prblock_set(3, 0xAA00BBCC);
    prblock_get(3);

    struct pr_bitstream_t test_bit;

    bitstream_capture(&pr_bit[ADD], &test_bit);

    printf("Capturing current state completed\n");
    fflush(stdout);

    //bitstream_save("partial_bitstreams/test.bit", &test_bit);

    prblock_set(3, 0x00DD0000);
    test_prblock(ADD);
    prblock_get(3);

    reconfigure_prblock(SUB);
    test_prblock(SUB);

    // send thread exit command
    mbox_put(&mb_in[HWT_DPR],THREAD_EXIT_CMD);

    sleep(1);
    printf("Performing restore now...\n");
    fflush(stdout);

    bitstream_restore(&test_bit);

    printf("Restore done\n");
    fflush(stdout);

    // reset hardware thread and start new delegate
    reconos_hwt_setresources(&hwt[HWT_DPR],res[HWT_DPR],2);
    reconos_hwt_create(&hwt[HWT_DPR],HWT_DPR,NULL);

    test_prblock(ADD);
    prblock_get(3);
  } else {
    printf("Readback mode, reading %d words from 0x%08X\n", g_arguments.read_words, g_arguments.read_far);

    uint32_t* mem = (uint32_t*) malloc(g_arguments.read_words * sizeof(uint32_t));
    if(mem == NULL) {
      printf("Could not allocate memory\n");
      return EXIT_FAILURE;
    }

    hw_icap_read(g_arguments.read_far, g_arguments.read_words, mem);

    unsigned int i;
    for(i = 0; i < g_arguments.read_words; i++) {
      printf("%08X\n", mem[i]);
    }
  }

	return 0;
}

