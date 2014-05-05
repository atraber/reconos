#ifndef ICAP_DEMO_H
#define ICAP_DEMO_H

// hw threads
#define NUM_SLOTS 3
#define HWT_ICAP  0
#define HWT_DPR   1
#define HWT_DPR2  2

#define ADD 0
#define SUB 1

#define THREAD_EXIT_CMD 0xFFFFFFFF

extern struct reconos_resource res[NUM_SLOTS][2];
extern struct reconos_hwt hwt[NUM_SLOTS];
extern struct mbox mb_in[NUM_SLOTS];
extern struct mbox mb_out[NUM_SLOTS];


struct pr_bitstream_t {
  uint32_t* block;
  unsigned int length; // in 32 bit words
};

extern struct pr_bitstream_t pr_bit[2];

int bitstream_open(const char* path, struct pr_bitstream_t* stream);
int bitstream_save(const char* path, struct pr_bitstream_t* stream);
int bitstream_capture(struct pr_bitstream_t* stream_in, struct pr_bitstream_t* stream_out);
int bitstream_restore(struct pr_bitstream_t* stream);


int hw_icap_write(uint32_t* addr, unsigned int size);
int hw_icap_write_frame(uint32_t far, uint32_t* addr, unsigned int words);
int sw_icap_write(uint32_t* addr, unsigned int size);

int sw_icap_load(int thread_id);
int hw_icap_load(int thread_id);
int linux_icap_load(int thread_id);

void icap_switch_bot();
void icap_switch_top();
void hwt_icap_clear_crc();

int hw_icap_read(uint32_t far, uint32_t size, uint32_t* dst);
int hw_icap_read_reg(uint8_t reg);
int hw_icap_gcapture();
int hw_icap_grestore();
int hw_icap_gsr();

#endif
