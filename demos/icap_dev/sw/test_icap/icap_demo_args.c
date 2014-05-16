#include <argp.h>

// ReconOS
#include "reconos.h"
#include "mbox.h"

#include "timing.h"
#include "icap_demo.h"


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
  {"far",     'f',  "FAR",  0,  "FAR to read from, must be in hex format (0xABCD)" },
  {"capture", 4000, 0,      0,  "Capture current state using GCAPTURE" },
  {"restore", 4100, 0,      0,  "Restore state using GSR" },
  {"test",    't',  "slot", OPTION_ARG_OPTIONAL, "Playground.. can be anything here" },
  {"test2",   6000, "slot", OPTION_ARG_OPTIONAL,  "Playground.. can be anything here" },
  {"test3",   6003, "slot", OPTION_ARG_OPTIONAL,  "Playground.. can be anything here" },
  {"switch_bot", 5000, 0,   0,  "Change to bottom ICAP interface" },
  {"switch_top", 5001, 0,   0,  "Change to top ICAP interface" },
  { 0 }
};

/* Parse a single option. */
static error_t
parse_opt (int key, char *arg, struct argp_state *state)
{
  /* Get the input argument from argp_parse, which we
     know is a pointer to our arguments structure. */
  struct cmd_arguments_t *arguments = (struct cmd_arguments_t*)state->input;

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

  case 5000:
    arguments->mode = MODE_SWITCH_BOT;
    break;

  case 5001:
    arguments->mode = MODE_SWITCH_TOP;
    break;

  case 't':
    arguments->mode = MODE_TEST;

    if(arg)
      arguments->slot = atoi(arg);
    break;

  case 6000:
    arguments->mode = MODE_TEST2;

    if(arg)
      arguments->slot = atoi(arg);
    break;

  case 6003:
    arguments->mode = MODE_TEST3;

    if(arg)
      arguments->slot = atoi(arg);
    break;

  case 'r':
    arguments->mode = MODE_READ;
    arguments->read_words = atoi(arg);
    break;

  case 'f':
    sscanf(arg, "0x%X", &arguments->read_far);
    break;

  case ARGP_KEY_INIT:
    // default values
    arguments->reconf_mode = RECONF_HW;
    arguments->mode = MODE_WRITE;
    arguments->max_cnt = 10;
    arguments->read_far = 0x8A80;
    arguments->read_words = 1;
    arguments->slot = HWT_DPR;
    break;

  case ARGP_KEY_FINI:
    if(arguments->slot >= NUM_SLOTS || arguments->slot < 0)
      argp_usage(state);
    break;

  default:
    return ARGP_ERR_UNKNOWN;
  }
  return 0;
}

static struct argp argp = { options, parse_opt, "", "" };

void cmd_parsing(int argc, char* argv[], struct cmd_arguments_t* arguments)
{
  argp_parse (&argp, argc, argv, 0, 0, arguments);
}
