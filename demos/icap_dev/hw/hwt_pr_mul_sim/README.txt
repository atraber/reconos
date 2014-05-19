The simulation model checks agaist an expected bitfile

Use partial_stim.hex as the stimuli bitfile and partial_check.hex as the responses

Usually those two files are identical, but to simulate CRC errors they can differ

The files have to be in hex format, 8 bytes per line (so 32 bits)

You can use the following command to convert from the binary bin file to hex:
  xxd -c 4 -p ./partial_add.bin > ./partial_check.hex
