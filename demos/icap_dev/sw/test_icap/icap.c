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

int g_activeICAP = ICAP_HW;

// selects the active ICAP interface, this can either be ICAP_HW or ICAP_SW
// all ICAP reads and ICAP writes then use the given interface
void icap_set(int icap)
{
  g_activeICAP = icap;
}

// load arbitrary cmd sequence via ICAP
// size must be in bytes
int icap_write(uint32_t* addr, unsigned int size)
{
  switch(g_activeICAP) {
  case ICAP_HW:
    return hw_icap_write(addr, size);

  case ICAP_SW:
    return sw_icap_write(addr, size);

  default:
    printf("The select ICAP interface is not available. Only ICAP_HW and ICAP_SW are currently supported\n");
    return 0;
  }
}

// size must be in bytes
int icap_read(uint32_t* addr, unsigned int size)
{
  switch(g_activeICAP) {
  case ICAP_HW:
    return hw_icap_read(addr, size);

  case ICAP_SW:
    return sw_icap_read(addr, size);

  default:
    printf("The select ICAP interface is not available. Only ICAP_HW and ICAP_SW are currently supported\n");
    return 0;
  }
}

int icap_read_frame(uint32_t far, uint32_t size, uint32_t* dst)
{
  switch(g_activeICAP) {
  case ICAP_HW:
    return hw_icap_read_frame(far, size, dst);

  case ICAP_SW:
    return sw_icap_read_frame(far, size, dst);

  default:
    printf("The select ICAP interface is not available. Only ICAP_HW and ICAP_SW are currently supported\n");
    return 0;
  }
}

int icap_write_frame(uint32_t far, uint32_t* addr, unsigned int words)
{
  switch(g_activeICAP) {
  case ICAP_HW:
    return hw_icap_write_frame(far, addr, words);

  case ICAP_SW:
    return sw_icap_write_frame(far, addr, words);

  default:
    printf("The select ICAP interface is not available. Only ICAP_HW and ICAP_SW are currently supported\n");
    return 0;
  }
}

int icap_gcapture()
{
  switch(g_activeICAP) {
  case ICAP_HW:
    return hw_icap_gcapture();

  case ICAP_SW:
    return sw_icap_gcapture();

  default:
    printf("The select ICAP interface is not available. Only ICAP_HW and ICAP_SW are currently supported\n");
    return 0;
  }
}

int icap_grestore()
{
  switch(g_activeICAP) {
  case ICAP_HW:
    return hw_icap_grestore();

  case ICAP_SW:
    return sw_icap_grestore();

  default:
    printf("The select ICAP interface is not available. Only ICAP_HW and ICAP_SW are currently supported\n");
    return 0;
  }
}
