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
#
# 	Running the script:
# 	sudo ./dma_memory_mapped_test.sh <xdma id> <io size> <io count> <h2c #> <c2h #>
#
# Argument 1: <xdma id>
# Example: xdma0
#
# Description: Base name used to build device node paths.
# 	- /dev/xdma0_h2c_0 (host -> card, channel 0)
# 	- /dev/xdma0_c2h_0 (card -> host, channel 0)
#
# Argument 2: <io size>
# Example: 1024
# Description: How many bytes to transfer per block.
# 	- Should be a power of 2.
# 	- If transferSz=1024, then each write/read will be 1024 bytes.
#
# Argument 3: <io count>
# Example: 1
# Description: How many times to repeat the transfer.
# 	- If ioCount=1, then each write/read will be repeated 1 time.
# 	- If ioCount=100, do 100 transfers (usually sequentially) of the same size to/from that address range.
# 	- This is useful for stress testing or reliability testing.
#
# Argument 4: <h2c #>
# Example: 4
# Description: How many H2C channels to use.
# 	- If h2cChannels=4, then 4 channels will be used to write data to the FPGA.
# 	- If h2cChannels=0, then no H2C channels will be used.
#
# Argument 5: <c2h #>
# Example: 4
# Description: How many C2H channels to use.
# 	- If c2hChannels=4, then 4 channels will be used to read data from the FPGA.
# 	- If c2hChannels=0, then no C2H channels will be used.
#
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

# Parse a comma-separated list of integers into a global array (name in $2).
# Usage: parse_int_list "0,2,1" block_list  -> block_list=(0 2 1)
parse_int_list() {
    local list="$1"
    local arrname="$2"
    eval "$arrname=()"
    [[ -z "$list" ]] && return
    local parts p
    IFS=',' read -ra parts <<< "$list"
    for p in "${parts[@]}"; do
        p=$(echo "$p" | tr -d ' ')
        [[ -z "$p" ]] && continue
        [[ "$p" =~ ^[0-9]+$ ]] || die "Block/order list must be comma-separated non-negative integers. Got: '$p' in '$list'"
        eval "$arrname+=(\"$p\")"
    done
}

# Resolve which blocks to test and write/read order. Sets global arrays:
#   block_list, write_order, read_order
# - If -b was provided, block_list is that list; else 0..(numBlocks-1).
# - write_order: from -W, else -o, else block_list.
# - read_order: from -R, else -o, else block_list.
# Validates: all indices >= 0 (integers). Optionally validate uniqueness (allow repeats if -b is used).
# Offsets: addrOffset = transferSz * blockIndex (block index, not iteration index).
resolve_block_and_orders() {
    local n=$1
    local b_arg="$2"
    local o_arg="$3"
    local w_arg="$4"
    local r_arg="$5"

    if [[ -n "$b_arg" ]]; then
        parse_int_list "$b_arg" block_list
    else
        block_list=()
        for ((i=0; i<n; i++)); do block_list+=( "$i" ); done
    fi

    if [[ -n "$w_arg" ]]; then
        parse_int_list "$w_arg" write_order
    elif [[ -n "$o_arg" ]]; then
        parse_int_list "$o_arg" write_order
    else
        write_order=( "${block_list[@]}" )
    fi

    if [[ -n "$r_arg" ]]; then
        parse_int_list "$r_arg" read_order
    elif [[ -n "$o_arg" ]]; then
        parse_int_list "$o_arg" read_order
    else
        read_order=( "${block_list[@]}" )
    fi

    # Require datafiles for every block index that appears in write_order or read_order
    for bi in "${write_order[@]}" "${read_order[@]}"; do
        local df="data/datafile${bi}_4K.bin"
        if [[ ! -f "$df" ]]; then
            die "Required data file missing: $df (block index $bi). Create it or adjust -b/-o/-W/-R."
        fi
    done
}

display_help() {
	echo "Usage: $0 <xdma id> <io size> <io count> <h2c #> <c2h #> [options]"
	echo ""
	echo "Positional arguments (required):"
	echo "  xdma id    \txdma[N], e.g. xdma0"
	echo "  io size    \tDMA transfer size in bytes"
	echo "  io count   \tDMA transfer count"
	echo "  h2c #      \tnumber of H2C channels"
	echo "  c2h #      \tnumber of C2H channels"
	echo ""
	echo "Optional flags (after the 5 positionals):"
	echo "  -n <numBlocks>   number of blocks to test (default: 4); ignored if -b is used"
	echo "  -b <blockList>   explicit block indices, e.g. \"0,2\" (overrides -n)"
	echo "  -o <order>       write+read order, e.g. \"2,0,1,3\" (default: 0,1,2,...)"
	echo "  -W <order>       write order only (if unset, use -o or default)"
	echo "  -R <order>       read order only (if unset, use -o or default)"
	echo "  -s               stop on first verify failure"
	echo "  -v               verbose: print hexdumps on compare failure (default: off)"
	echo "  -h               show this help"
	echo ""
	echo "Examples:"
	echo "  # Default: 4 blocks, order 0,1,2,3"
	echo "  sudo $0 xdma0 32 1 1 1"
	echo ""
	echo "  # One block only (block 0)"
	echo "  sudo $0 xdma0 32 1 1 1 -b 0"
	echo ""
	echo "  # Reorder: write and read in order 2,0,1,3"
	echo "  sudo $0 xdma0 32 1 1 1 -o 2,0,1,3"
	echo ""
	echo "  # Only two blocks (0 and 2)"
	echo "  sudo $0 xdma0 32 1 1 1 -b 0,2"
	echo ""
	echo "  # Separate write and read order"
	echo "  sudo $0 xdma0 32 1 1 1 -W 2,0,1,3 -R 0,2,1,3"
	echo ""
	exit 1
}

if [ $# -lt 5 ]; then
	display_help
fi

# ----------------------------- argument parsing -----------------------------
xid=$1
transferSz=$2
transferCount=$3
h2cChannels=$4
c2hChannels=$5
shift 5

# Optional (defaults)
numBlocks=4
blockListArg=""
orderArg=""
writeOrderArg=""
readOrderArg=""
stopOnFailure=0
verboseHexdump=0

while [[ $# -gt 0 ]]; do
    case $1 in
        -n) numBlocks=$2; shift 2 ;;
        -b) blockListArg=$2; shift 2 ;;
        -o) orderArg=$2; shift 2 ;;
        -W) writeOrderArg=$2; shift 2 ;;
        -R) readOrderArg=$2; shift 2 ;;
        -s) stopOnFailure=1; shift ;;
        -v) verboseHexdump=1; shift ;;
        -h) display_help ;;
        *) die "Unknown option: $1. Use -h for help." ;;
    esac
done

# ----------------------------- sanity checks --------------------------------

# Ensure numbers look like numbers (basic check).
[[ "$transferSz" =~ ^[0-9]+$ ]] || die "io size must be an integer bytes value. Got: '$transferSz'"
[[ "$transferCount" =~ ^[0-9]+$ ]] || die "io count must be an integer. Got: '$transferCount'"
[[ "$h2cChannels" =~ ^[0-9]+$ ]] || die "h2c # must be an integer. Got: '$h2cChannels'"
[[ "$c2hChannels" =~ ^[0-9]+$ ]] || die "c2h # must be an integer. Got: '$c2hChannels'"
[[ "$numBlocks" =~ ^[0-9]+$ ]] || die "numBlocks (-n) must be a non-negative integer. Got: '$numBlocks'"

# Resolve block list and write/read orders (also validates datafiles exist)
resolve_block_and_orders "$numBlocks" "$blockListArg" "$orderArg" "$writeOrderArg" "$readOrderArg"

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
# If h2cChannels > 0, we write blocks in write_order. Channel round-robin is
# based on iteration index: curChannel = iterationIndex % h2cChannels.
# addrOffset = transferSz * blockIndex (block index, not iteration).
#
# We run each dma_to_device in the background (&); after we have started one
# job on each available channel, we call `wait` before starting more.
###############################################################################

if [ $h2cChannels -gt 0 ]; then
	log "Starting H2C writes (Host -> Card)..."
	iter=0
	for blockIndex in "${write_order[@]}"; do
		addrOffset=$(($transferSz * blockIndex))
		curChannel=$((iter % h2cChannels))
		dev="/dev/${xid}_h2c_${curChannel}"
		in_file="data/datafile${blockIndex}_4K.bin"

		log "WRITE blockIndex=${blockIndex} iterationIndex=${iter} channel=${curChannel} offset=${addrOffset} dev=${dev} file=${in_file}"

		"$dma_to" \
			-d "$dev" \
			-f "$in_file" \
			-s "$transferSz" \
			-a "$addrOffset" \
			-c "$transferCount" &
		if [ $((curChannel + 1)) -eq $h2cChannels ]; then
			log "H2C: all channels busy; waiting for current writes to finish..."
			wait
		fi
		iter=$((iter + 1))
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
# If c2hChannels > 0, we read blocks in read_order. Channel round-robin is
# based on iteration index: curChannel = iterationIndex % c2hChannels.
# addrOffset = transferSz * blockIndex.
###############################################################################
if [ $c2hChannels -gt 0 ]; then
	log "Starting C2H reads (Card -> Host)..."
	iter=0
	for blockIndex in "${read_order[@]}"; do
		addrOffset=$(($transferSz * blockIndex))
		curChannel=$((iter % c2hChannels))
		dev="/dev/${xid}_c2h_${curChannel}"
		out_file="data/output_datafile${blockIndex}_4K.bin"

		rm -f "$out_file"

		log "READ  blockIndex=${blockIndex} iterationIndex=${iter} channel=${curChannel} offset=${addrOffset} dev=${dev} out=${out_file}"

		"$dma_from" \
			-d "$dev" \
			-f "$out_file" \
			-s "$transferSz" \
			-a "$addrOffset" \
			-c "$transferCount" &
		if [ $((curChannel + 1)) -eq $c2hChannels ]; then
			log "C2H: all channels busy; waiting for current reads to finish..."
			wait
		fi
		iter=$((iter + 1))
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
	iter=0
	for blockIndex in "${read_order[@]}"; do
		in_file="data/datafile${blockIndex}_4K.bin"
		out_file="data/output_datafile${blockIndex}_4K.bin"
		addrOffset=$((transferSz * blockIndex))

		log "VERIFY blockIndex=${blockIndex} iterationIndex=${iter} offset=${addrOffset} in=${in_file} out=${out_file} size=${transferSz}"

		cmp "$out_file" "$in_file" -n "$transferSz"
		rc=$?

		start=$((blockIndex * transferSz))
		end=$(((blockIndex + 1) * transferSz - 1))

		if [ $rc -ne 0 ]; then
			log "FAIL: Data mismatch for blockIndex=${blockIndex}"
			log "      address range (FPGA offset): ${start} - ${end}"
			log "      write file: ${in_file}"
			log "      read  file: ${out_file}"

			# Hexdump on failure only when -v (verbose) is set
			if [ "$verboseHexdump" -eq 1 ]; then
				echo ""
				echo "========== EXPECTED DATA (input file) =========="
				hexdump -C -n "$transferSz" "$in_file"
				echo ""
				echo "========== ACTUAL DATA (output file) =========="
				hexdump -C -n "$transferSz" "$out_file"
				echo "================================================"
				echo ""
			fi

			testError=1
			if [ "$stopOnFailure" -eq 1 ]; then
				log "Stopping on first failure (-s)."
				break
			fi
		else
			log "PASS: Data matched for blockIndex=${blockIndex}"
		fi
		iter=$((iter + 1))
	done
fi

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
