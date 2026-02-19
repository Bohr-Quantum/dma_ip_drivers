#!/bin/bash

###############################################################################
# dma_memory_mapped_test.sh
#
#  This is a "write some bytes, read them back, compare files" test for XDMA.
#
#   1) Arguments:
#        - which XDMA device name to use (like xdma0)
#        - transfer size (bytes)
#        - transfer count (how many transfers)
#        - number of H2C channels (Host -> Card writes)
#        - number of C2H channels (Card -> Host reads)
#
#   2) The script writes 4 chunks of data into 4 address regions on the FPGA,
#      using H2C channels in a round-robin pattern, with parallel background jobs.
#
#   3) Then it reads those 4 chunks back from the same address regions,
#      using C2H channels in a round-robin pattern, also in parallel.
#
#   4) Finally, it compares each read file to the original write file (cmp)
#      and prints pass/fail for each chunk.
#
# Why 4 loops (i=0..3)?
#   It tests four adjacent memory "blocks" at address offsets:
#     0*transferSz, 1*transferSz, 2*transferSz, 3*transferSz
#
# What "transferCount" does:
#   The dma_to_device / dma_from_device tools typically support repeating
#   the transfer multiple times. This test expects repeatable correctness.
###############################################################################

# ----------------------------- helper functions -----------------------------

log() {
    # Simple logger
    echo "[dma_memory_mapped_test] $*"
}

warn() {
  echo "[dma_memory_mapped_test][WARN] $*" 1>&2
}

die() {
    # Print an error and exit non-zero.
    echo "[dma_memory_mapped_test][ERROR] $*" 1>&2
    exit 1
}

display_help() {
	echo "$0 <xdma id> <io size> <io count> <h2c #> <c2h #>"
	echo -e "xdma id:\txdma[N] "
	echo -e "io size:\tdma transfer size in byte"
	echo -e "io count:\tdma transfer count"
       	echo -e "h2c #:\tnumber of h2c channels"
	echo -e "c2h #:\tnumber of c2h channels"
       	echo
       
	exit 1
}

if [ $# -eq 0 ]; then
	display_help
fi


# ----------------------------- argument parsing -----------------------------
xid=$1
transferSz=$2
transferCount=$3
h2cChannels=$4
c2hChannels=$5

# ----------------------------- sanity checks --------------------------------

# Ensure numbers look like numbers (basic check).
[[ "$transferSz" =~ ^[0-9]+$ ]] || die "io size must be an integer bytes value. Got: '$transferSz'"
[[ "$transferCount" =~ ^[0-9]+$ ]] || die "io count must be an integer. Got: '$transferCount'"
[[ "$h2cChannels" =~ ^[0-9]+$ ]] || die "h2c # must be an integer. Got: '$h2cChannels'"
[[ "$c2hChannels" =~ ^[0-9]+$ ]] || die "c2h # must be an integer. Got: '$c2hChannels'"

tool_path=../tools
dma_to="${tool_path}/dma_to_device"
dma_from="${tool_path}/dma_from_device"

testError=0
# Run the PCIe DMA memory mapped write read test
log "Running PCIe DMA memory mapped write read test"
log "xid='${xid}', transferSz=${transferSz}, transferCount=${transferCount}, h2cChannels=${h2cChannels}, c2hChannels=${c2hChannels}"


###############################################################################
# STEP 1: WRITE (Host -> Card)
###############################################################################
#
# If h2cChannels > 0, we write 4 blocks. We choose which channel to use by:
#     curChannel = i % h2cChannels
#
# We run each dma_to_device command in the background (&) so multiple channels
# can be active at once.
#
# After we have started one job on each available channel, we call `wait` to
# wait for those background jobs to finish before starting more.
###############################################################################

if [ $h2cChannels -gt 0 ]; then
	log "Starting H2C writes (Host -> Card)..."
	# Loop over four blocks of size $transferSz and write to them
	for ((i=0; i<=3; i++)); do
		addrOffset=$(($transferSz * $i))
		curChannel=$(($i % $h2cChannels))
		
		dev="/dev/${xid}_h2c_${curChannel}"
    	in_file="data/datafile${i}_4K.bin"

		log "WRITE block i=${i}: channel=${curChannel}, dev=${dev}, offset=${addrOffset}, size=${transferSz}, count=${transferCount}, file=${in_file}"

		# $dma_to -d ${dev} -f ${in_file} -s ${transferSz} -a ${addrOffset} -c ${transferCount} &
		# $tool_path/dma_to_device -d /dev/${xid}_h2c_${curChannel} \
		#        	-f data/datafile${i}_4K.bin -s $transferSz \
		# 	-a $addrOffset -c $transferCount &

		"$dma_to" \
      		-d "$dev" \
      		-f "$in_file" \
      		-s "$transferSz" \
      		-a "$addrOffset" \
      		-c "$transferCount" &
		# If all channels have active transactions we must wait for
	        # them to complete
		if [ $(($curChannel+1)) -eq $h2cChannels ]; then
      		log "H2C: all channels busy; waiting for current writes to finish..."
      		wait
		fi
	done
else
	warn "No H2C channels enabled. Skipping write test."
fi

# Wait for the last transaction to complete.
wait
log "H2C writes completed."

###############################################################################
# STEP 2: READ (Card -> Host)
###############################################################################
#
# If c2hChannels > 0, we read 4 blocks back from the same offsets.
# Same channel selection pattern:
#     curChannel = i % c2hChannels
#
# Also parallelized with background jobs and `wait`.
###############################################################################
if [ $c2hChannels -gt 0 ]; then
	log "Starting C2H reads (Card -> Host)..."
	# Loop over four blocks of size $transferSz and read from them
	for ((i=0; i<=3; i++)); do
		addrOffset=$(($transferSz * $i))
		curChannel=$(($i % $c2hChannels))

		dev="/dev/${xid}_c2h_${curChannel}"
    	out_file="data/output_datafile${i}_4K.bin"

    	# Remove any previous output so we don't accidentally compare stale data.
    	rm -f "$out_file"

		log "READ  block i=${i}: channel=${curChannel}, dev=${dev}, offset=${addrOffset}, size=${transferSz}, count=${transferCount}, out=${out_file}"

    	"$dma_from" \
      		-d "$dev" \
      		-f "$out_file" \
      		-s "$transferSz" \
      		-a "$addrOffset" \
      		-c "$transferCount" &
		# echo "Info: Reading from c2h channel $curChannel at " \
		# 	"address offset $addrOffset."
		# $tool_path/dma_from_device -d /dev/${xid}_c2h_${curChannel} \
		#        	-f data/output_datafile${i}_4K.bin -s $transferSz \
		#        	-a $addrOffset -c $transferCount &
		# If all channels have active transactions we must wait for
	        # them to complete
		if [ $(($curChannel+1)) -eq $c2hChannels ]; then
			log "C2H: all channels busy; waiting for current reads to finish..."
			wait
		fi
	done
else
	warn "No C2H channels enabled. Skipping read test."
fi

# Wait for the last transaction to complete.
wait
log "C2H reads completed."

###############################################################################
# STEP 3: VERIFY (Compare read data vs written data)
###############################################################################
#
# We can only verify if BOTH:
#   - we actually wrote something (h2cChannels > 0)
#   - we actually read something (c2hChannels > 0)
#
# For each of the 4 blocks:
#   cmp output_file input_file -n transferSz
# If cmp returns non-zero, data mismatch occurred.
###############################################################################

# Verify that the written data matches the read data if possible.
if [ $h2cChannels -eq 0 ]; then
	log "No verification: h2cChannels=0 (nothing was written)."
elif [ $c2hChannels -eq 0 ]; then
	warn "No data verification: c2hChannels=0 (nothing was read)."
else
	log "Checking data integrity..."
	for ((i=0; i<=3; i++)); do
	    in_file="data/datafile${i}_4K.bin"
	    out_file="data/output_datafile${i}_4K.bin"

	    log "VERIFY block i=${i}: in=${in_file}, out=${out_file}, size=${transferSz}"

	    cmp "$out_file" "$in_file" -n "$transferSz"
	    rc=$?

	    if [ $rc -ne 0 ]; then
			log "FAIL: Data mismatch for block i=${i}"
			log "      address range: ${start} - ${end}"
			log "      write file:    ${in_file}"
			log "      read file:     ${out_file}"
			testError=1
    	else
			log "PASS: Data matched for block i=${i}"
    	fi
	done
else
	warn "No data verification."
fi

# 		cmp data/output_datafile${i}_4K.bin data/datafile${i}_4K.bin \
# 			-n $transferSz
# 		returnVal=$?
# 	       	if [ ! $returnVal == 0 ]; then
# 			echo "Error: The data written did not match the data" \
# 			       " that was read."
# 			echo -e "\taddress range: " \
# 				"$(($i*$transferSz)) - $((($i+1)*$transferSz))"
# 			echo -e "\twrite data file: data/datafile${i}_4K.bin"
# 			echo -e "\tread data file:  data/output_datafile${i}_4K.bin"
# 			testError=1
# 		else
# 			echo "Info: Data check passed for address range " \
# 				"$(($i*$transferSz)) - $((($i+1)*$transferSz))"
# 		fi
# 	done
# fi


###############################################################################
# STEP 4: EXIT STATUS
###############################################################################
#
# Exit 0 if all passed, exit 1 if any compare failed.
###############################################################################

if [ "$testError" -eq 1 ]; then
  die "Test completed with errors."
fi

log "All PCIe DMA memory mapped tests passed."
exit 0
