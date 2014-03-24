#!/bin/bash


################################################################################
#                                                                              #
#                      CONFIGURATION A, ADDITION                               #
#                                                                              #
################################################################################
echo "######################################################################"
echo "BUILDING CONFIGURATION A"
echo "######################################################################"

# Make sure that we are really building the addition
sed -i '67s/.*/\tresult1 <= val1 + val2;/' ./pcores/hwt_pr_block_v1_00_a/hdl/vhdl/hwt_pr_block.vhd

################################################################################
# Building netlist
################################################################################
echo "run netlist" | xps -nw ./system.xmp

################################################################################
# Move netlist to new folder where PAR is executed
################################################################################
cp ./implementation/*.ngc ../pr_design/syn/static/

# Netlist of Reconfigurable Module is moved to a folder specific for this
# configuration
mv ../pr_design/syn/static/system_hwt_pr_block_0_wrapper.ngc ../pr_design/syn/pr_a/

echo "CONFIGURATION A FINISHED"

################################################################################
#                                                                              #
#                      CONFIGURATION B, SUBTRACTION                            #
#                                                                              #
################################################################################
echo "######################################################################"
echo "BUILDING CONFIGURATION B"
echo "######################################################################"

# Make sure that we are really building the subtraction
sed -i '67s/.*/\tresult1 <= val1 - val2;/' ./pcores/hwt_pr_block_v1_00_a/hdl/vhdl/hwt_pr_block.vhd

################################################################################
# Building netlist
################################################################################
echo "run netlist" | xps -nw ./system.xmp

################################################################################
# Move netlist to new folder where PAR is executed
################################################################################
cp ./implementation/*.ngc ../pr_design/syn/static/

# Netlist of Reconfigurable Module is moved to a folder specific for this
# configuration
mv ../pr_design/syn/static/system_hwt_pr_block_0_wrapper.ngc ../pr_design/syn/pr_b/

echo "CONFIGURATION B FINISHED"


# restore addition as this is what is on git, we do not want useless commits for
# this stuff
sed -i '67s/.*/\tresult1 <= val1 + val2;/' ./pcores/hwt_pr_block_v1_00_a/hdl/vhdl/hwt_pr_block.vhd
