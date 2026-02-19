#!/bin/bash
# set -x

###############################################################################
# load_driver.sh
#
#   1) Ensures you are root (required for kernel module operations).
#   2) Unloads the existing `xdma` kernel module if it is already loaded.
#   3) Loads the XDMA driver (`xdma.ko`) with a chosen interrupt mode.
#      - You can force a mode via argument 0..4
#      - Or leave it blank to auto-detect MSI-X / MSI / Legacy.
#   4) Verifies the driver registered its character devices by checking
#      `/proc/devices` for "xdma".
#
# Why interrupts matter:
#   DMA transfers are asynchronous. With interrupts enabled, the FPGA/PCIe
#   device can notify the CPU when a DMA transfer completes (more efficient).
#   In poll mode, the driver repeatedly checks status registers instead.
###############################################################################

# set -x  # Uncomment for verbose bash tracing (debugging)

# ----------------------------- helper functions -----------------------------


display_help() {
        echo "$0 [interrupt mode]"
        echo "interrupt mode: optional"
        echo "0: auto"
        echo "1: MSI"
        echo "2: Legacy"
        echo "3: MSIx"
        echo "4: do not use interrupt, poll mode only"
        exit;
}

if [ "$1" == "help" ]; then
        display_help
fi;

log() {
    # Simple logger
    echo "[load_driver] $*"
}

die() {
    # Print an error and exit non-zero.
    echo "[load_driver][ERROR] $*" 1>&2
    exit 1
}

insmod_xdma() {
    # Runs insmod and returns the *exit status*.
    local args="$1"

    log "Running: insmod ../xdma/xdma.ko ${args}"
    insmod ../xdma/xdma.ko ${args}
    local rc=$?

    if [ $rc -ne 0 ]; then
        log "insmod failed with exit code ${rc}"
    else
        log "insmod succeeded"
    fi

    return $rc
}

interrupt_selection=$1
echo "interrupt_selection $interrupt_selection."
device_id=9048

# Make sure only root can run our script
if [[ $EUID -ne 0 ]]; then
	# echo "This script must be run as root" 1>&2
    die "This script must be run as root"
fi

# Remove the existing xdma kernel module
log "Checking for existing xdma kernel module"
lsmod | grep xdma
if [ $? -eq 0 ]; then
	log "xdma is currently loaded. Unloading..."
	rmmod xdma
	if [ $? -ne 0 ]; then
		# echo "rmmod xdma failed: $?"
		die "rmmod xdma failed: $?"
	fi
	log "xdma module unloaded successfully"
else
	log "xdma module is not loaded"
fi

# Use the following command to Load the driver in the default 
# or interrupt drive mode. This will allow the driver to use 
# interrupts to signal when DMA transfers are completed.
log "Loading driver..."
case $interrupt_selection in
	"0")
		# echo "insmod xdma.ko interrupt_mode=1 ..."
		log "Mode: auto-detect (default)"
		ret=`insmod ../xdma/xdma.ko interrupt_mode=0`
		;;
	"1")
		# echo "insmod xdma.ko interrupt_mode=2 ..."
		log "Mode: MSI (interrupt_mode=1)"
		ret=`insmod ../xdma/xdma.ko interrupt_mode=1`
		;;
	"2")
		# echo "insmod xdma.ko interrupt_mode=3 ..."
		log "Mode: Legacy (interrupt_mode=2)"
		ret=`insmod ../xdma/xdma.ko interrupt_mode=2`
		;;
	"3")
		# echo "insmod xdma.ko interrupt_mode=4 ..."
		log "Mode: MSI-X (interrupt_mode=3)"
		ret=`insmod ../xdma/xdma.ko interrupt_mode=3`
		;;
	"4")
		# echo "insmod xdma.ko poll_mode=1 ..."
		log "Mode: Poll (poll_mode=1)"
		ret=`insmod ../xdma/xdma.ko poll_mode=1`
		;;
	*)
		log "Mode: auto-detect (no mode specified)"
		intp=`sudo lspci -d :${device_id} -v | grep -o -E "MSI-X"`
		intp1=`sudo lspci -d :${device_id} -v | grep -o -E "MSI:"`
	       	if [[ ( -n $intp ) && ( $intp == "MSI-X" ) ]]; then
			# echo "insmod xdma.ko interrupt_mode=0 ..."
			log "Mode: auto-detect (MSI-X detected)"
			ret=`insmod ../xdma/xdma.ko interrupt_mode=0`
	       	elif [[ ( -n $intp1 ) && ( $intp1 == "MSI:" ) ]]; then
			# echo "insmod xdma.ko interrupt_mode=1 ..."
			log "Mode: auto-detect (MSI detected)"
			ret=`insmod ../xdma/xdma.ko interrupt_mode=1`
		else
			# echo "insmod xdma.ko interrupt_mode=2 ..."
			log "Mode: auto-detect (Legacy detected)"
			ret=`insmod ../xdma/xdma.ko interrupt_mode=2`
		fi
		;;
esac

if [ ! $ret == 0 ]; then
	# echo "Error: xdma driver did not load properly"
	die "FAILURE: xdma driver did not load properly"
fi

# Check to see if the xdma devices were recognized
echo ""
cat /proc/devices | grep xdma > /dev/null
returnVal=$?
if [ $returnVal == 0 ]; then
	# Installed devices were recognized.
	log "The Kernel module installed correctly and the xmda devices were recognized."
else
	# No devices were installed.
	# echo "Error: The Kernel module installed correctly, but no devices were recognized."
	die "FAILURE: The Kernel module installed correctly, but no devices were recognized."
fi

log "DONE"
