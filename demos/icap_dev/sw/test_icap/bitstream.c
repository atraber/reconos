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

#include <arpa/inet.h>

// ReconOS
#include "reconos.h"
#include "mbox.h"

#include "icap_demo.h"


// preload bitstream and save it in memory
// Returns 1 if successfull, 0 otherwise
int bitstream_open(const char* path, struct pr_bitstream_t* stream)
{
  int retval = 0;

  FILE* fp = fopen(path, "r");
  if(fp == NULL) {
    printf("bitstream_open: Could not open file %s\n", path);

    goto FAIL;
  }

  // determine file size
  fseek(fp, 0L, SEEK_END);
  stream->length = ftell(fp);

  fseek(fp, 0L, SEEK_SET);

  if((stream->length & 0x3) != 0) {
    printf("bitstream_open: File size is not a multiple of 4 bytes\n");

    goto FAIL;
  }

  // convert file size from bytes to 32 bit words
  stream->length = stream->length / 4;

  // allocate memory for file
  stream->block = (uint32_t*)malloc(stream->length * sizeof(uint32_t));
  if(stream->block == NULL) {
    printf("bitstream_open: Could not allocate memory\n");

    goto FAIL;
  }

  // read whole file in one command
  if( fread(stream->block, sizeof(uint32_t), stream->length, fp) != stream->length) {
    printf("bitstream_open: Something went wrong while reading from file\n");

    free(stream->block);

    goto FAIL;
  }

  // check if we can find the synchronization sequence, this is usally in the first few words
  // if we can't find it in the first 20 words, there probably is no synchronization sequence
  unsigned int i;
  for(i = 0; i < 20; i++) {
    if( stream->block[i] == 0xAA995566 ) {
      // we have found the synchronization sequence
      retval = 1;
      break;
    }
  }
  
  // free the already loaded bitstream, it seems to be invalid
  if(retval == 0) {
    printf("bitstream_open: Bitstream seems to be invalid, no synchronization sequence found!\n");
    free(stream->block);
  }

FAIL:
  fclose(fp);

  return retval;
}

struct pr_frame_t {
  uint32_t far;
  uint32_t offset; // offset from start in bitstream in words
  uint32_t words; // in words
};

#define MAX_PR_FRAMES 64

int bitstream_capture(struct pr_bitstream_t* stream_in, struct pr_bitstream_t* stream_out)
{
  // copy input stream as we override it with the current values in the FPGA
  stream_out->length = stream_in->length;
  stream_out->block = (uint32_t*)malloc(stream_out->length * sizeof(uint32_t));
  memcpy(stream_out->block, stream_in->block, stream_out->length * sizeof(uint32_t));

  if(stream_out->block == NULL) {
    printf("bitstream_capture: Could not allocate memory\n");
    return 0;
  }

  unsigned int numFrames = 0;
  struct pr_frame_t arrFrames[MAX_PR_FRAMES];

  //----------------------------------------------------------------------------
  // parse bitstream
  //----------------------------------------------------------------------------
  uint8_t synced = 0; 
  uint32_t lastFar = 0xAABBCCDD;

  // overwrite CRC checks as they will fail anyway after capturing the new values
  unsigned int i;
  for(i = 0; i < stream_in->length; i++) {
    uint32_t word = htonl(stream_in->block[i]);

    if(!synced) {
      if(word == 0xAA995566)
        synced = 1;
    } else {
      // we are synchronized, now real commands follow
      uint8_t header = word >> 29;
      uint8_t opcode = (word >> 27) & 0x3;

      if(header == 0x1) {
        // type 1 packet

        if(opcode == 0) {
          // NOOP
        } else if(opcode == 2) {
          // write
          uint8_t regaddr = (word >> 13) & 0x1F;
          unsigned int packet_counter = word & (0x7FF);

          // decode register
          switch(regaddr) {
            case 0: // CRC
              // replace CRC command with NOOP as we are not doing CRC calculations
              stream_out->block[i] = htonl(0x20000000);

              if(packet_counter != 1 || (i + 1) >= stream_out->length) {
                printf("bitstream_capture: Bitstream seems to be invalid!\n");
                return 0;
              }

              stream_out->block[i + 1] = htonl(0x20000000);
              i++;
              break;

            case 1: // FAR
              if(packet_counter != 1 || (i + 1) >= stream_out->length) {
                printf("Bitstream seems to be invalid!\n");
                return 0;
              }

              lastFar = htonl(stream_in->block[i + 1]);
              i++;
              break;

            case 2: // FDRI
              if(packet_counter != 0 || (i + 1) >= stream_out->length) {
                printf("Bitstream seems to be invalid!\n");
                return 0;
              }

              word = htonl(stream_in->block[i + 1]);
              header = word >> 29;
              packet_counter = word & (0x7FFFFFF);

              if( header != 0x2 || (i + 1 + packet_counter) >= stream_out->length) {
                printf("Bitstream seems to be invalid!\n");
                return 0;
              }

              if(numFrames >= MAX_PR_FRAMES) {
                printf("Bitstream contains too many frames, a maximum of %d frames are supported\n", MAX_PR_FRAMES);
                return 0;
              }

              arrFrames[numFrames].far = lastFar;
              arrFrames[numFrames].offset = i + 2;
              arrFrames[numFrames].words = packet_counter;
              numFrames++;

              i += packet_counter + 1;
              break;

            case 4: // CMD
              if(packet_counter != 1 || (i + 1) >= stream_out->length) {
                printf("Bitstream seems to be invalid!\n");
                return 0;
              }

              word = htonl(stream_in->block[i + 1]);

              // desync received
              if(word == 13)
                synced = 0;

              i++;
              break;

            default:
              break;
          }
        }
      } else if(header == 0x2) {
        // type 2 packet

        // TODO!
      }
    }
  }

  if(numFrames == 0) {
    printf("Did not find any configuration frames in the bitstream\n");
    return 0;
  }

  // DEBUG CODE
  printf("The following frames have been found in the bitstream:\n");
  for(i = 0; i < numFrames; i++) {
    printf("FAR: 0x%08X, Size: %d, Offset: %d\n", arrFrames[i].far, arrFrames[i].words, arrFrames[i].offset);
  }


  fflush(stdout);

  //----------------------------------------------------------------------------
  // write CFG_CLB to FPGA
  //----------------------------------------------------------------------------

  // first check if we have a CFG_CLB section, should be the first one in the blocks array
  if(arrFrames[0].far != 0x00400000) {
    printf("Did not find CFG_CLB block in bitstream\n");
    return 0;
  }

  icap_write_frame(arrFrames[0].far, stream_out->block + arrFrames[0].offset, arrFrames[0].words);

  //----------------------------------------------------------------------------
  // do gcapture
  //----------------------------------------------------------------------------

  icap_gcapture();

  //----------------------------------------------------------------------------
  // readback of data
  //----------------------------------------------------------------------------

  // the first frame is ignored as this is the CFG_CLB frame which we have just wrote to the FPGA
  for(i = 1; i < numFrames; i++) {
    // if((arrFrames[i].far & 0xFFE00000) == 0x00200000) {
    //   printf("FAR 0x%08X points to RAM region, skipping it as we cannot handle it reliably\n", arrFrames[i].far);
    //   continue;
    // }

    icap_read_frame(arrFrames[i].far, arrFrames[i].words, stream_out->block + arrFrames[i].offset);
  }

  return 1;
}

int bitstream_save(const char* path, struct pr_bitstream_t* stream)
{
  int retval = 0;

  FILE* fp = fopen(path, "w");
  if(fp == NULL) {
    printf("Could not open file %s\n", path);

    goto FAIL;
  }

  size_t size = stream->length;
  // write whole file in one command
  if( fwrite(stream->block, sizeof(uint32_t), size, fp) != size) {
    printf("Something went wrong while writing to file\n");

    goto FAIL;
  }

  retval = 1;

FAIL:
  if(fp != NULL)
    fclose(fp);

  return retval;
}

int bitstream_restore(struct pr_bitstream_t* stream)
{
  icap_write(stream->block, stream->length * 4);

  icap_grestore();

  return 1;
}
