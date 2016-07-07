#!/usr/bin/awk -f
#
# Usage:  PrintGCFixup.pc [file ...]
#
# Cleanup HotSpot GC logs so they are more readable and amenable to analysis
# with PrintGCStats.  The following cleanups are performed:
#
# 1) Strip -XX:+PrintHeapAtGCOutput.
# 
# 2) Move -XX:+PrintVMOptions output so it doesn't interfere with GC output.
#
# 3) Strip -XX:+TraceClassUnloading output.
# 
# 4) Move the output from -XX:+PrintParallelOldGCPhaseTimes from the middle of
#    -XX:+PrintGCDetails output to just before it.
#
#    The 1.5.0 updates that contain the parallel old collector use the label
#    'post compact' for the phase that updates interior oops in objects that
#    were deferred because they cross compaction boundaries.  Also, no timers
#    cover the phase in which data structures are reset after compaction.
#    Later VMs use the label 'deferred updates' for the phase in which deferred
#    objects are updated, and label the time resetting data structures as 'post
#    compact.'  If 1.5.0 output is detected, the label 'post compact' is
#    converted to 'deferred updates' to allow comparison of 1.5.0 and later VMs.
#
# 5) Move -XX:+PrintTenuringDistribution output from the middle of the GC
#    output to just before it.
# 
# 6) Move g1 'evac failed' messages from the middle of the GC output to just
#    before it.
#
# 7) Fix misleading 'Full GC' messages from JNI critical sections w/CMS.
#
# 8) Change cms concurrent mode failure output so the concurrent phase line is
#    before the full gc output instead of in the middle.
# 
# 9) Move the output from -XX:+TraceParallelOldGCSummaryPhase from the middle of
#    GC output.
# ------------------------------------------------------------------------------

BEGIN {
	vm_option_prefix = "";
	unloading_class_prefix = "";

	# Regular expressions to match PrintHeapAtGC header lines.
 	ph_hdr_beg_ns_re = "\\{Heap before (GC|gc) invocations=";
	ph_hdr_end_ns_re = "\\{?Heap after (GC|gc) invocations=";

	# Some VM versions print a space at the start of the PrintHeapAtGC
	# header line and some don't.  These variables are set to the correct
	# regular expression (including the space or not) once it is known.
	ph_hdr_beg_re = "";
	ph_hdr_end_re = "";

	# Regular expression to match a 'generation' line in -XX:+PrintHeapAtGC
	# output.
	ph_gen_re = "^ +";
	ph_gen_re = ph_gen_re "(((AS)?PS|Par)(Young|Old|Perm)Gen";
	ph_gen_re = ph_gen_re "|(par|def) new generation";
	ph_gen_re = ph_gen_re "|concurrent[ -]mark-sweep (generation|perm gen)";
	ph_gen_re = ph_gen_re "|tenured generation|compacting perm gen";
	ph_gen_re = ph_gen_re ") +total [0-9]+[KMG], used [0-9]+[KMG]";

	# Regular expression to match a 'space' line in -XX:+PrintHeapAtGC
	# output.
	ph_spc_re = "^ +";
	ph_spc_re = ph_spc_re "(eden|from|to  |object|the|r[ow]) space";
	ph_spc_re = ph_spc_re " +[0-9]+[KMG], +[0-9]+% used";

	full_gc_re		= "\\[Full GC( \\(System\\))? ";
	full_gc_ns_re		= substr(full_gc_re, 1, length(full_gc_re) - 1);
	heap_size_re		= "[0-9]+[KM]";				# 8K
	heap_size_paren_re	= "\\(" heap_size_re "\\)";		# (8K)
	heap_size_change_re	= heap_size_re "->" heap_size_re;	# 8K->4K
	# 8K->4K(96K), or 8K->4K (96K)
	heap_size_status_re	= heap_size_change_re " ?" heap_size_paren_re;

	gc_time_re		= "[0-9]+\\.[0-9]+";
	gc_time_secs_re		= gc_time_re " secs";
	gc_time_ms_re		= gc_time_re " ms";
	timestamp_re		= "(" gc_time_re ": *)?";
	timestamp_range_re	= "(" gc_time_re "-" gc_time_re ": *)?";

	# Heap size status plus elapsed time:  8K->4K(96K), 0.0517089 secs
	heap_report_re		= heap_size_status_re ", " gc_time_secs_re;

	# Size printed at CMS initial mark and remark.
	cms_heap_size_re	= heap_size_re heap_size_paren_re;	# 6K(9K)
	cms_heap_report_re	= cms_heap_size_re ", " gc_time_secs_re;
	cms_concurrent_phase_re = "(AS)?CMS-concurrent-(mark|(abortable-)?preclean|sweep|reset)";

	# Generations which print optional messages.
	promo_failed_re		= "( \\(promotion failed\\))?"
	cms_gen_re		= "(AS)?CMS( \\(concurrent mode failure\\))?";
	parnew_gen_re		= "(AS)?ParNew";
	# 'Framework' GCs:  DefNew, ParNew, Tenured, CMS
	fw_yng_gen_re		= "(DefNew|" parnew_gen_re ")" promo_failed_re;
	fw_old_gen_re		= "(Tenured|" cms_gen_re ")";

	# Garbage First (G1) pauses:
	#    [GC pause (young), 0.0082 secs]
	# or [GC pause (partial), 0.082 secs]
	# or [GC pause (young) (initial mark), 0.082 secs]
	# or [GC remark, 0.082 secs]
	# or [GC cleanup 11M->11M(25M), 0.126 secs]
	g1_cleanup_re		= "cleanup " heap_size_status_re;
	g1_pause_re		= "pause \\((young|partial)\\)";
	g1_pause_re		= g1_pause_re "( \\((initial-mark|evacuation failed)\\))?";
	g1_stw_re		= "\\[GC (" g1_pause_re "|remark|" g1_cleanup_re "), " \
				gc_time_secs_re "\\]";

	# PrintTenuringDistribution (ptd)
	ptd_initial_re		= "^Desired survivor size [0-9]+ [a-zA-Z]+, new threshold [0-9]+";
	ptd_age_re		 = "^- age +[0-9]+: +[0-9]+ [a-zA-Z]+, +[0-9]+ total$";

	# Used to determine if the label 'post compact' should be converted to
	# 'deferred updates' 
	deferred_updates_line = -1;
}

# ------------------------------------------------------------------------------
# Strip -XX:+PrintHeapAtGCOutput
# ------------------------------------------------------------------------------

function is_print_heap_at_gc_hdr(string) {
	if (ph_hdr_beg_re != "") {
		if (match(string, ph_hdr_beg_re)) return 1;
		if (match(string, ph_hdr_end_re)) return 2;
		return 0;
	}

	# Try to determine whether or not this VM prints a space at the start
	# of the header line or not.
	if (match(string, "^ " ph_hdr_beg_ns_re) || \
	    match(string, "  " ph_hdr_beg_ns_re)) {
		# This VM prints a space before the header.
		ph_hdr_beg_re = " " ph_hdr_beg_ns_re;
		ph_hdr_end_re = " " ph_hdr_end_ns_re;
		match(string, ph_hdr_beg_re);	# Set RSTART, RLENGTH correctly.
		return 1;
	}

	if (match(string, "^ " ph_hdr_end_ns_re) || \
	    match(string, "  " ph_hdr_end_ns_re)) {
		# This VM prints a space before the header.
		ph_hdr_beg_re = " " ph_hdr_beg_ns_re;
		ph_hdr_end_re = " " ph_hdr_end_ns_re;
		match(string, ph_hdr_end_re);	# Set RSTART, RLENGTH correctly.
		return 2;
	}

	if (match(string, ph_hdr_beg_ns_re)) {
		# This VM does not print a space before the header.
		ph_hdr_beg_re = ph_hdr_beg_ns_re;
		ph_hdr_end_re = ph_hdr_end_ns_re;
		return 1;
	}

	if (match(string, ph_hdr_end_ns_re)) {
		# This VM does not print a space before the header.
		ph_hdr_beg_re = " " ph_hdr_beg_ns_re;
		ph_hdr_end_re = " " ph_hdr_end_ns_re;
		return 2;
	}

	return 0;
}

function is_print_heap_at_gc_line(string) {
	if (string == "Heap" || string == "}") return 1;
	if (match(string, ph_gen_re)) return 1;
	if (match(string, ph_spc_re)) return 1;
	if (string == "No shared spaces configured.") return 1;	# Ugh.
	return 0;
}

function skip_print_heap_at_gc_lines() {
	while (is_print_heap_at_gc_line($0)) {
		getline;
	}
	if (match($0, "^} ")) {
		$0 = substr($0, 3);
	}
}

{
	rc = is_print_heap_at_gc_hdr($0);
	while (rc) {
		if (RSTART > 1) {
			ph_saved_text = substr($0, 1, RSTART - 1);
		} else {
			ph_saved_text = "";
		}
		getline;
		skip_print_heap_at_gc_lines();
		$0 = ph_saved_text $0;
		rc = is_print_heap_at_gc_hdr($0);
	}
}

# ------------------------------------------------------------------------------
# Strip gc overhead messages.
# ------------------------------------------------------------------------------

match($0, "\tGC (overhead|time) would exceed GC(Overhead|Time)Limit of [0-9]+%")  && RSTART > 1 {
	gcol_saved_txt = substr($0, 1, RSTART - 1);
	print substr($0, RSTART + 1, RLENGTH);
	getline;
	$0 = gcol_saved_txt $0;
}

# ------------------------------------------------------------------------------

# Strip i-cms duty cycle output.
#
# 23.136: [GC 23.137: [ParNew: 65408K->0K(65472K), 0.0737562 secs] 72847K->13616K(1048512K) icms_dc=5 , 0.0741636 secs]

# By default, icms duty cycle output is stripped.  Allow 
# '-v keep_icms_dc=1' on the command line to override that.
keep_icms_dc == 0 && match($0, heap_size_status_re " icms_dc=[0-9]+ ") {
	sub(" icms_dc=[0-9]+ ", "");
	# Note:  no 'next' here; need to allow other patterns see the input.
}

# ------------------------------------------------------------------------------
# Fix -XX:+PrintVMOptions output.
# 
# Change this:
# 
# [GCVM option '+UseParallelOldGC'
# VM option '+UseParallelGC'
# VM option '+PrintGCDetails'
# VM option 'ParallelGCThreads=4'
#  [PSYoungGen: 3004K->503K(3584K)] 3004K->2850K(7680K), 0.0191534 secs]
# 
# to this:
# 
# VM option '+UseParallelOldGC'
# VM option '+UseParallelGC'
# VM option '+PrintGCDetails'
# VM option 'ParallelGCThreads=4'
# [GC [PSYoungGen: 3004K->503K(3584K)] 3004K->2850K(7680K), 0.0191534 secs]
# ------------------------------------------------------------------------------

vm_option_prefix == "" && match($0, "VM option '.+'") {
	if (RSTART > 1) {
		vm_option_prefix = substr($0, 1, RSTART - 1);
		# Print the VM option.
		print substr($0, RSTART);
		next;
	}
}

vm_option_prefix != "" {
	if (match($0, "^VM option '.+'")) {
		print;
		next;
	} else {
		$0 = vm_option_prefix $0;
		vm_option_prefix = "";
	}
}

# ------------------------------------------------------------------------------
# Strip -XX:+TraceClassUnloading output which, unfortunately, is enabled as a
# side-effect of -XX:+PrintGCDetails.
# ------------------------------------------------------------------------------

unloading_class_prefix == "" && match($0, "\\[Unloading class [^]]+\\]") {
	if (RSTART > 1) {
		unloading_class_prefix = substr($0, 1, RSTART - 1);
		# print substr($0, RSTART, length($0) - RSTART + 1);
		next;
	}
}

unloading_class_prefix != "" {
	if (match($0, "^\\[Unloading class [^]]+\\]")) {
		# print;
		next;
	} else {
		$0 = unloading_class_prefix $0;
		unloading_class_prefix = "";
	}
}

# ------------------------------------------------------------------------------
# Move the output from -XX:+PrintParallelOldGCPhaseTimes from the middle of
# -XX:+PrintGCDetails output to just before the PrintGCDetails output.  For
# example, change this:
# 
# 0.012: [pre compact, 0.0000074 secs]
# 0.012: [Full GC0.012: [par marking phase0.012: [par marking main, 0.0071655 secs]
# 0.019: [reference processing, 0.0000417 secs]
# 0.019: [class unloading, 0.0010241 secs]
# , 0.0083858 secs]
# 0.021: [summary phase, 0.0014581 secs]
# 0.022: [adjust roots, 0.0014760 secs]
# 0.024: [compact perm gen, 0.0109628 secs]
# 0.035: [drain task setup, 0.0012706 secs]
# 0.036: [dense prefix task setup, 0.0000058 secs]
# 0.036: [steal task setup, 0.0000013 secs]
# 0.036: [par compact, 0.0059447 secs]
# 0.042: [deferred updates, 0.0026215 secs]
# 0.045: [post compact, 0.0008886 secs]
#  [PSYoungGen: 503K->0K(3584K)] [ParOldGen: 2347K->2838K(7744K)] 2850K->2838K(11328K) [PSPermGen: 1457K->1456K(16384K)], 0.0340510 secs]
#
# to this:
# 
# 0.012: [pre compact, 0.0000074 secs]
# 0.012: [par marking main, 0.0071655 secs]
# 0.019: [reference processing, 0.0000417 secs]
# 0.019: [class unloading, 0.0010241 secs]
# 0.012: [par marking phase, 0.0083858 secs]
# 0.021: [summary phase, 0.0014581 secs]
# 0.022: [adjust roots, 0.0014760 secs]
# 0.024: [compact perm gen, 0.0109628 secs]
# 0.035: [drain task setup, 0.0012706 secs]
# 0.036: [dense prefix task setup, 0.0000058 secs]
# 0.036: [steal task setup, 0.0000013 secs]
# 0.036: [par compact, 0.0059447 secs]
# 0.042: [deferred updates, 0.0026215 secs]
# 0.045: [post compact, 0.0008886 secs]
# 0.012: [Full GC [PSYoungGen: 503K->0K(3584K)] [ParOldGen: 2347K->2838K(7744K)] 2850K->2838K(11328K) [PSPermGen: 1457K->1456K(16384K)], 0.0340510 secs]
# ------------------------------------------------------------------------------

# The marking phase may have nested items; fix them up.
/\[(par )?marking phase.*\[par mark *[,:]/ {
	match($0, timestamp_re "\\[par mark *[,:] " gc_time_secs_re "\\]");
 	print substr($0, RSTART, RLENGTH);	# [par marking main, ...]

	# Reunite the first (outer) 'marking phase' text with its time.
 	tmp1 = substr($0, 1, RSTART - 1);
 	tmp2 = substr($0, RSTART + RLENGTH);
	while (getline tmp3 > 0 && !match(tmp3, "^[,:] " gc_time_secs_re "\\]")) {
		print tmp3;
	}
 	$0 = tmp1 tmp2 tmp3;
}

match($0, timestamp_re "\\[(par )?marking phase *[,:] " gc_time_secs_re "\\]") {
	# print NR, RSTART, RLENGTH ":" $0;
	pc_saved_text = substr($0, 1, RSTART - 1);
	print substr($0, RSTART, length($0) - RSTART + 1);
	next;
}

# The compaction phase may have nested items; fix them up.
/\[compaction phase.*\[drain task setup *[,:]/ {
	match($0, timestamp_re "\\[drain task setup *[,:] " gc_time_secs_re "\\]");
 	print substr($0, RSTART, RLENGTH);	# [par compact, ...]

	# Reunite the 'compaction phase' text with the associated time.
 	tmp1 = substr($0, 1, RSTART - 1);
 	tmp2 = substr($0, RSTART + RLENGTH);
	while (getline tmp3 > 0 && !match(tmp3, "^[,:] " gc_time_secs_re "\\]")) {
		if (match(tmp3, "\\[deferred updates *[,:] " gc_time_secs_re "\\]")) {
			deferred_updates_line = NR;
		}
		print tmp3;
	}
 	$0 = tmp1 tmp2 tmp3;
}

/\[deferred updates *[,:] [0-9][0-9.]* secs\]/ {
	print;
	deferred_updates_line = NR;
	next;
}

/\[post compact *[,:] [0-9][0-9.]* secs\]/ {
	# If the deferred updates line has not been seen, this is an older VM
	# that labels the deferred updates phase as 'post compact.'  Fix it up.
	if (deferred_updates_line < 0) {
		sub("post compact", "deferred updates");
	} else {
		# Reset deferred_updates_line, since we may process multiple
		# files, some from older from VMs.
		deferred_updates_line = -1;
	}
	print;
	printf("%s", pc_saved_text);	# Note:  no newline.
	next;
}

# ------------------------------------------------------------------------------
# Strip -XX:+PrintTenuringDistribution output.
# ------------------------------------------------------------------------------

# DefNew/Parnew before:
# 
# [GC [DefNew
# Desired survivor size 32768 bytes, new threshold 1 (max 31)
# - age   1:       5280 bytes,      65280 total
# - age   2:       9820 bytes,      65280 total
# - age   3:      50180 bytes,      65280 total
# : 2111K->63K(2112K), 0.0003662 secs] 3415K->1383K(3520K), 0.0004358 secs]
#
# After:
# 
# [GC [DefNew: 2111K->63K(2112K), 0.0003662 secs] 3415K->1383K(3520K), 0.0004358 secs]
# 
# Parallel scavenge before:
# 
# [GC
# Desired survivor size 1572864 bytes, new threshold 7 (max 15)
#  [PSYoungGen: 8571K->1299K(10752K)] 8571K->8331K(35328K), 0.0257617 secs]
# 
# After:
# 
# [GC [PSYoungGen: 8571K->1299K(10752K)] 8571K->8331K(35328K), 0.0257617 secs]

match($0, "^" timestamp_re "\\[GC( " timestamp_re "\\[" fw_yng_gen_re ")?$") {
	td_saved_text = $0;
	getline;
	if (match ($0, ptd_initial_re)) {
		print; getline;
		while (match($0, ptd_age_re)) {
			print; getline;
		}
	}

	# This may not be the correct result if the ptd_initial_re line
	# ("Desired  survivor size") was not matched.  However, since we've done
	# a getline it's too late to do anything else.
	$0 = td_saved_text $0;
}

# ------------------------------------------------------------------------------
# G1 evac failed messages.
# ------------------------------------------------------------------------------

# [GC pause (young)evac failed in heap region 01051e8 [0xf7400000,0xf7500000), (F: age 0) first obj = 0xf74d1440
# evac failed in heap region 0104cc8 [0xf7300000,0xf7400000), (F: age 0) first obj = 0xf73db610
# ...
# (evacuation failed), 0.16025130 secs]

match($0, "\\[GC " g1_pause_re "evac failed in heap region") {
	g1_saved_len = RLENGTH - 26;
	g1_saved_txt = substr($0, RSTART, g1_saved_len);
	print substr($0, RSTART + g1_saved_len);
	getline;
	while (match($0, "^evac failed in heap region")) {
		print;
		getline;
	}
	$0 = g1_saved_txt $0;
}

# ------------------------------------------------------------------------------
# Fix misleading 'Full GC' messages from JNI critical sections w/CMS.
# ------------------------------------------------------------------------------

# Get rid of the 'Full' in the following:
# 
# 5806.397: [Full GC 5806.397: [ParNew: 21817K->9930K(183680K), 0.1656553 secs] 246236K->240893K(1022336K), 0.1660009 secs]

match($0, full_gc_re timestamp_re "\\[ParNew: " heap_report_re "\\] " heap_report_re "\\]$") {
	t1 = substr($0, 1, RSTART);
	t2 = substr($0, RSTART + 6);
	$0 = t1 t2;
}

# ------------------------------------------------------------------------------
# Change cms concurrent mode failure output so the concurrent phase line is
# before the full gc output instead of in the middle.
# ------------------------------------------------------------------------------

# Before:
# 
# 2.139: [GC 2.139: [ParNew: 7814K->7814K(8128K), 0.0000347 secs]2.139: [CMS2.139: [CMS-concurrent-abortable-preclean: 0.050/1.184 secs]
#  (concurrent mode failure): 248160K->251282K(251400K), 0.3042057 secs] 255974K->255969K(259528K), 0.3045270 secs]
#
# After:
# 
# 2.139: [CMS-concurrent-abortable-preclean: 0.050/1.184 secs]
# 2.139: [GC 2.139: [ParNew: 7814K->7814K(8128K), 0.0000347 secs]2.139: [CMS (concurrent mode failure): 248160K->251282K(251400K), 0.3042057 secs] 255974K->255969K(259528K), 0.3045270 secs]

match($0, timestamp_re "\\[CMS" timestamp_re "\\[" cms_concurrent_phase_re ": +" gc_time_re "/" gc_time_secs_re "\\]$") {
	match($0, timestamp_re "\\[" cms_concurrent_phase_re ": +");
	cms_cmf_saved_txt = substr($0, 1, RSTART - 1);
	print substr($0, RSTART);
	getline;
	$0 = cms_cmf_saved_txt $0;
}

# ------------------------------------------------------------------------------
# Change 'Perm :' to 'Perm:'
# ------------------------------------------------------------------------------

# Remove the space before the colon.
match($0, "\\[(CMS )?Perm :") {
	$0 = substr($0, 1, RSTART + RLENGTH - 3) \
		substr($0, RSTART + RLENGTH - 1);
}

# ------------------------------------------------------------------------------
# Clean up the output from -XX:+TraceParallelOldGCSummaryPhase
# ------------------------------------------------------------------------------

match($0, "^" timestamp_re full_gc_ns_re "sb=") {
	pc_saved_txt = substr($0, RSTART, RLENGTH - 3);
	$0 = substr($0, RSTART + RLENGTH - 3);
}

match($0, "^ \\[PSYoungGen: " heap_size_status_re "\\]") {
	$0 = pc_saved_txt $0;
}

# ------------------------------------------------------------------------------

{ print; }

