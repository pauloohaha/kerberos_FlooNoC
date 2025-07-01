#!/bin/bash

source /cad/modules/tcl/init/sh
module load base

# VCS
module load vcs/T-2022.06-SP2
module load verdi/T-2022.06-SP2

# QuestaSim
export VSIM_HOME=/cad/mentor/2021.4/questasim/
module load questa/2021.4

# SpyGlass
module load spyglass/S-2021.09-1

#Include PATHs
export PATH=$PATH:/sim2/piao/install/bender/bin/
export PATH=/sim2/piao/install/llvm_snitch/bin:$PATH

export CPATH=/usr/include/$CPATH

conda activate floonoc