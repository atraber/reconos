#ifndef ICAP_DEMO_H
#define ICAP_DEMO_H

// hw threads
#define NUM_SLOTS 2
#define HWT_ICAP  0
#define HWT_DPR   1

#define ADD 0
#define SUB 1

#define THREAD_EXIT_CMD 0xFFFFFFFF

extern struct reconos_resource res[NUM_SLOTS][2];
extern struct reconos_hwt hwt[NUM_SLOTS];
extern struct mbox mb_in[NUM_SLOTS];
extern struct mbox mb_out[NUM_SLOTS];


int cache_bitstream(int thread_id, const char* path);
int hw_icap_write(uint32_t* addr, unsigned int size);
int sw_icap_write(uint32_t* addr, unsigned int size);
int sw_icap_load(int thread_id);
int hw_icap_load(int thread_id);
int linux_icap_load(int thread_id);

void icap_switch_bot();
void icap_switch_top();
void hwt_icap_clear_crc();


#endif
