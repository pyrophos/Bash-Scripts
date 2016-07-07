#!/usr/bin/awk -f

# Note:  /bin/nawk on Solaris 9 seems to have a bug; the RSTART and RLENGTH
# vars are not set correctly during the last call to match() in
# recordGCPauseEVM.

# PrintGCStats - summarize statistics about garbage collection, in particular gc
# pause time totals, averages, maximum and standard deviations.
# 
# Attribution:  written by John Coomes, based on earlier work by Peter Kessler,
# Ross Knippel and Jon Masamitsu.
#
# The input to this script should be the output from the HotSpot(TM)
# Virtual Machine when run with one or more of the following flags:
#
# -verbose:gc			# produces minimal output so statistics are
#				# limited, but available in all VMs
#
# -XX:+PrintGCTimeStamps	# enables time-based statistics (e.g.,
#				# allocation rates, intervals), but only
#				# available in JDK 1.4.0 and later.
#
# -XX:+PrintGCDetails		# enables more detailed statistics gathering,
#				# but only available in JDK 1.4.1 and later.
#
# -XX:-TraceClassUnloading	# [1.5.0 and later] disable messages about class
#				# unloading, which are enabled as a side-effect
#				# by -XX:+PrintGCDetails.  The class unloading
#				# messages confuse this script and will cause
#				# some GC information in the log to be ignored.
#				# 
#				# Note:  This option only has an effect in 1.5.0
#				# and later.  Prior to 1.5.0, the option is
#				# accepted, but is overridden by
#				# -XX:+PrintGCDetails. In 1.4.2 and earlier
#				# releases, use -XX:-ClassUnloading instead (see
#				# below).
#
# -XX:-ClassUnloading		# disable class unloading, since PrintGCDetails
#				# turns on TraceClassUnloading, which cannot be
#				# overridden from the command line until 1.5.0.
#
# Recommended command-line with JDK 1.5.0 and later:
#
#	java -verbose:gc -XX:+PrintGCTimeStamps -XX:+PrintGCDetails \
#		-XX:-TraceClassUnloading ...
#
# Recommended command-line with JDK 1.4.1 and 1.4.2:
#
#	java -verbose:gc -XX:+PrintGCTimeStamps -XX:+PrintGCDetails \
#		-XX:-ClassUnloading ...
#
# ------------------------------------------------------------------------------
# 
# Usage:
#
# PrintGCStats -v cpus=<n> [-v interval=<seconds>] [-v verbose=1] [file ...]
# PrintGCStats -v plot=name [-v plotcolumns=<n>] [-v verbose=1] [file ...]
# 
# cpus		- number of cpus on the machine where java was run, used to
#		  compute cpu time available and gc 'load' factors.  No default;
#		  must be specified on the command line (defaulting to 1 is too
#		  error prone).
#
# ncpu		- synonym for cpus, accepted for backward compatibility
#
# interval	- print statistics at the end of each interval; requires
#		  output from -XX:+PrintGCTimeStamps.  Default is 0 (disabled).
#
# plot		- generate data points useful for plotting one of the collected
#		  statistics instead of the normal statistics summary.  The name
#		  argument is the name of one of the output statistics, e.g.,
#		  "gen0t(s)", "cmsRM(s)", "commit0(MB)", etc.
# 
# 		  The default output format for time-based statistics such as
# 		  "gen0t(s)" includes four columns, described below.  The
# 		  default output format for size-based statistics such as
# 		  "commit0(MB)" includes just the first two columns.  The
# 		  number of columns in the output can be set on the command
# 		  line with -v plotcolumns=<N>.
# 
# 		  The output columns are:
#
#		  1) the starting timestamp if timestamps are present, or a
#		     simple counter if not
#
#		  2) the value of the desired statistic (e.g., the length of a
#		     cms remark pause).
#
#		  3) the ending timestamp (or counter)
#
#		  4) the value of the desired statistic (again)
#
#		  The last column is to make plotting start & stop events
#		  easier.
#
# plotcolumns	- the number of columns to include in the plot data.
#
# verbose	- if non-zero, print each item on a separate line in addition
#		  to the summary statistics
# 
# Typical usage:
#
# PrintGCStats -v cpus=4 gc.log > gc.stats
# 
# ------------------------------------------------------------------------------
#
# Basic Output statistics:
#
# gen0(s)     - young gen collection time, excluding gc_prologue & gc_epilogue.
# gen0t(s)    - young gen collection time, including gc_prologue & gc_epilogue
# gen1i(s)    - train generation incremental collection
# gen1t(s)    - old generation collection/full GC
# cmsIM(s)    - CMS initial mark pause
# cmsRM(s)    - CMS remark pause
# cmsRS(s)    - CMS resize pause
# GC(s)       - all stop-the-world GC pauses
# cmsCM(s)    - CMS concurrent mark phase
# cmsCP(s)    - CMS concurrent preclean phase
# cmsCS(s)    - CMS concurrent sweep phase
# cmsCR(s)    - CMS concurrent reset phase
# alloc(MB)   - object allocation in MB (approximate***)
# promo(MB)   - object promotion in MB (approximate***)
# used0(MB)   - young gen used memory size (before gc)
# used1(MB)   - old gen used memory size (before gc)
# used(MB)    - heap space used memory size (before gc) (excludes perm gen)
# commit0(MB) - young gen committed memory size (after gc)
# commit1(MB) - old gen committed memory size (after gc)
# commit(MB)  - heap committed memory size (after gc) (excludes perm gen)
# apptime(s)  - amount of time application threads were running
# safept(s)   - amount of time the VM spent at safepoints (app threads stopped)
#
# *** - these values are approximate because there is no way to track
#       allocations that occur directly into older generations.
# 
# Some definitions:
# 
# 'mutator' or 'mutator thread':  a gc-centric term referring to a non-GC
# thread that modifies or 'mutates' the heap by allocating memory and/or
# updating object fields.
# 
# promotion:  when an object that was allocated in the young generation has
# survived long enough, it is copied, or promoted, into the old generation.
#
# Time-based Output Statistics (require -XX:+PrintGCTimeStamps):
# 
# alloc/elapsed_time - allocation rate, based on elapsed time
# alloc/tot_cpu_time - allocation rate, based on total cpu time
# alloc/mut_cpu_time - allocation rate, based on cpu time available to mutators
# promo/elapsed_time - promotion rate, based on elapsed time
# promo/gc0_time     - promotion rate, based on young gen gc time
# gc_seq_load        - the percentage of cpu cycles used by gc 'serially'
#		       (i.e., while java application threads are stopped)
# gc_conc_load       - the percentage of cpu cycles used by gc 'concurrently'
# 		       (i.e., while java application threads are also running)
# gc_tot_load        - the percentage of cpu cycles spent in gc

BEGIN {
  usage_msg = "PrintGCStats -v cpus=<n> [-v interval=<seconds>] " \
	      "[-v verbose=1] [file ...]\n" \
              "PrintGCStats -v plot=name [-v plotcolumns=<n>] "\
	      "[-v verbose=1] [file ...]";

  # Seconds between printing per-interval statistics; a negative value disables
  # intervals (the default).  Allow command line to override.
  timeStampDelta = interval == 0 ? -1 : interval;

  # Number of cpus.  Require this on the command line since defaulting to 1 is
  # too error prone.  Older versions used ncpu as the var name; accept it for
  # compatibility.
  if (cpus == 0) cpus = ncpu;
  if (cpus == 0 && plot == "") {
    print usage_msg;
    exit(1);
  }

  # A note on time stamps:  the firstTimeStamp is not always assumed to be 0 so
  # that we can get accurate elapsed time measurement for a partial log (e.g.,
  # from the steady-state portion of a log from a long running server).  This
  # means that the elapsed time measurement can be wrong if a program runs for a
  # significant amount of time before the first gc time stamp is reported.  The
  # best way to fix this is to have the VM emit a time stamp when heap
  # initialization is complete.
  firstTimeStamp = -1.0;	# sentinel
  prevTimeStamp = lastTimeStamp = firstTimeStamp;

  lastFileName = "";	# Used to detect when the input file has changed.

  # This value is added to time stamps so that input from multiple files appears
  # to have monotonically increasing timestamps.
  timeStampOffset = 0.0;

  i = -1;
  gen0c_idx = ++i;	# With PrintGCDetails, DefNew collection time only.
  gen0t_idx = ++i;	# Includes gc_prologue() & gc_epilogue().
  gen1i_idx = ++i;	# Train incremental collection time. 
  gen1t_idx = ++i;	# Full GCs or Tenured GCs
  cmsIM_idx = ++i;	# CMS Initial Mark
  cmsRM_idx = ++i;	# CMS Remark
  cmsRS_idx = ++i;	# CMS Resize (evm only)
  totgc_idx = ++i;	# Total gc pause time

  # These must be greater than the totgc_idx.
  cmsCM_idx = ++i;	# CMS Concurrent Mark
  cmsCP_idx = ++i;	# CMS Concurrent Preclean
  cmsCS_idx = ++i;	# CMS Concurrent Sweep
  cmsCR_idx = ++i;	# CMS Concurrent Reset
  MB_a_idx = ++i;	# MB allocated
  MB_p_idx = ++i;	# MB promoted
  MB_used0_idx = ++i;	# MB used in young gen
  MB_used1_idx = ++i;	# MB used in old gen
  MB_usedh_idx = ++i;	# MB used in heap (occupancy)
  MB_c0_idx = ++i;	# MB committed for gen0
  MB_c1_idx = ++i;	# MB committed for gen1
  MB_ch_idx = ++i;	# MB committed for entire heap

  safept_idx = ++i;	# Time application threads were stopped at a safepoint,
  			# from -XX:+TraceGCApplicationStoppedTime

  apptime_idx =	++i;	# Time application threads were running, from
  			# -XX:+PrintGCApplicationConcurrentTime

  # Parallel old phases from PrintParallelOldGCPhaseTimes.
  PO_precomp_idx	= ++i;
  PO_marking_idx	= ++i;
  PO_parmark_idx	= ++i;
  PO_mark_flush_idx	= ++i;
  PO_summary_idx 	= ++i;
  PO_adjroots_idx	= ++i;
  PO_permgen_idx	= ++i;
  PO_compact_idx 	= ++i;
  PO_drain_ts_idx 	= ++i;
  PO_dpre_ts_idx 	= ++i;
  PO_steal_ts_idx 	= ++i;
  PO_parcomp_idx 	= ++i;
  PO_deferred_idx	= ++i;
  PO_postcomp_idx	= ++i;

  last_idx = ++i;	# This is just the last *named* index; a corresponding
			# delta_* array item exists for each of the above items
			# starting at this point in the array.

  plot_cnt = -1;	# Used to identify plot lines if timestamps are not
  			# available.

  # Init arrays.
  name_v[gen0c_idx]	= "gen0(s)";
  name_v[gen0t_idx]	= "gen0t(s)";
  name_v[gen1i_idx]	= "gen1i(s)";
  name_v[gen1t_idx]	= "gen1t(s)";
  name_v[cmsIM_idx]	= "cmsIM(s)";
  name_v[cmsRM_idx]	= "cmsRM(s)";
  name_v[cmsRS_idx]	= "cmsRS(s)";
  name_v[totgc_idx]	= "GC(s)";
  name_v[cmsCM_idx]	= "cmsCM(s)";
  name_v[cmsCP_idx]	= "cmsCP(s)";
  name_v[cmsCS_idx]	= "cmsCS(s)";
  name_v[cmsCR_idx]	= "cmsCR(s)";
  name_v[MB_a_idx]	= "alloc(MB)";
  name_v[MB_p_idx]	= "promo(MB)";
  name_v[MB_used0_idx]	= "used0(MB)";
  name_v[MB_used1_idx]	= "used1(MB)";
  name_v[MB_usedh_idx]	= "used(MB)";
  name_v[MB_c0_idx]	= "commit0(MB)";
  name_v[MB_c1_idx]	= "commit1(MB)";
  name_v[MB_ch_idx]	= "commit(MB)";
  name_v[safept_idx]	= "safept(s)";
  name_v[apptime_idx]	= "apptime(s)";

  name_v[PO_precomp_idx]	= "precomp(s)";
  name_v[PO_marking_idx]	= "marking(s)";
  name_v[PO_parmark_idx]	= "parmark(s)";
  name_v[PO_mark_flush_idx]	= "mark-f(s)";
  name_v[PO_summary_idx]	= "summary(s)";
  name_v[PO_adjroots_idx]	= "adjroots(s)";
  name_v[PO_permgen_idx]	= "permgen(s)";
  name_v[PO_compact_idx]	= "compact(s)";
  name_v[PO_drain_ts_idx]	= "drain_ts(s)";
  name_v[PO_dpre_ts_idx]	= "dpre_ts(s)";
  name_v[PO_steal_ts_idx]	= "steal_ts(s)";
  name_v[PO_parcomp_idx]	= "parcomp(s)";
  name_v[PO_deferred_idx]	= "deferred(s)";
  name_v[PO_postcomp_idx]	= "postcomp(s)";

  for (i = 0; i < last_idx; ++i) {
    count_v[i] = 0;
    sum_v[i] = 0.0;
    max_v[i] = 0.0;
    sum_of_sq_v[i] = 0.0;
    name_v[last_idx + i] = name_v[i];	# Copy names.
  }

  plot_idx = -1;
  if (plot != "") {
    # Convert the plot=name value to a plot_idx.  The default is no plotting,
    # which occurs when plot_idx < 0.
    for (i = 0; plot_idx < 0 && i < last_idx; ++i) {
      if (plot == name_v[i]) {
	plot_idx = i;
      }
    }

    if (plot_idx < 0) {
      print "PrintGCStats:  unrecognized plot name plot=" plot ".";
      print usage_msg;
      exit(1);
    }
  }

  # If plotting, set plotcolumns based on the statistic being plotted (unless
  # plotcolumns was set on the command line).
  if (plot_idx >= 0 && plotcolumns == 0) {
    if (plot_idx >= MB_a_idx && plot_idx <= MB_ch_idx) {
      # Use 2 columns for size-based statistics.
      plotcolumns = 2;
    } else {
      # Use 4 columns for time-based statistics.
      plotcolumns = 4;
    }
  }

  # Heap sizes at the start & end of the last gen0 collection.
  gen0_sizes[0] = 0.0;
  gen0_sizes[1] = 0.0;
  gen0_sizes[2] = 0.0;

  initIntervalVars();

  last_cmsRcount = 0;
  printFirstHeader = 1;

  # Six columns:  name, count, total, mean, max, standard deviation
  headfmt = "%-11s" "  %7s" "  %13s"   "  %12s"   "  %12s"   "  %9s"   "\n";
  datafmt = "%-11s" "  %7d" "  %13.3f" "  %12.5f" "  %12.3f" "  %9.4f" "\n";

  # Frequently-used regular expressions.
  # These are replicated in PrintGCFixup; keep them in sync.
  full_gc_re		= "\\[Full GC (\\(System\\) )?";
  heap_size_re		= "[0-9]+[KM]";				# 8K
  heap_size_paren_re	= "\\(" heap_size_re "\\)";		# (8K)
  heap_size_change_re	= heap_size_re "->" heap_size_re;	# 8K->4K
  # 8K->4K(96K), or 8K->4K (96K)
  heap_size_status_re	= heap_size_change_re " ?" heap_size_paren_re;

  gc_time_re		= "[0-9]+\\.[0-9]+";
  gc_time_secs_re	= gc_time_re " secs";
  gc_time_ms_re		= gc_time_re " ms";
  timestamp_re		= "(" gc_time_re ": *)?";
  timestamp_range_re	= "(" gc_time_re "-" gc_time_re ": *)?";

  # Heap size status plus elapsed time:  8K->4K(96K), 0.0517089 secs
  heap_report_re	= heap_size_status_re ", " gc_time_secs_re;

  # Size printed at CMS initial mark and remark.
  cms_heap_size_re	= heap_size_re heap_size_paren_re;	# 6K(9K)
  cms_heap_report_re	= cms_heap_size_re ", " gc_time_secs_re;
  cms_concurrent_phase_re = "(AS)?CMS-concurrent-(mark|(abortable-)?preclean|sweep|reset)";

  # Generations which print optional messages.
  promo_failed_re	= "( \\(promotion failed\\))?"
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
}

function initIntervalVars() {
  for (i = 0; i < last_idx; ++i) {
    count_v[last_idx + i] = 0;
    sum_v[last_idx + i] = 0.0;
    max_v[last_idx + i] = 0.0;
    sum_of_sq_v[last_idx + i] = 0.0;
  }
}

function ratio(dividend, divisor) {
  result = 0.0;
  if (divisor != 0.0) {
    result = dividend / divisor;
  }
  return result;
}

function stddev(count, sum, sum_of_squares) {
  if (count < 2) return 0.0;
  sum_squared_over_count = (sum * sum) / count;
  # This has happened on occasion--not sure why--but only for total gc time,
  # which includes samples from different populations.
  if (sum_of_squares < sum_squared_over_count) return -1.0;
#  print "stddev", count, sum, sum_of_squares, sum_squared_over_count;
  return sqrt((sum_of_squares - sum_squared_over_count) / (count - 1));
}

function printHeader() {
  printf(headfmt, "what", "count", "total", "mean", "max", "stddev");
}

function printData(idx) {
  cnt = count_v[idx];
  sec = sum_v[idx];
  sd = stddev(cnt, sec, sum_of_sq_v[idx]);
  printf(datafmt, name_v[idx], cnt, sec, ratio(sec, cnt), max_v[idx], sd);
}

function printRate(name, tot, tot_units, period, period_units) {
  printf("%-21s = %10.3f %-2s / %10.3f %-2s = %7.3f %s/%s\n",
    name, tot, tot_units, period, period_units, ratio(tot, period),
    tot_units, period_units);
}

function printPercent(name, tot, tot_units, period, period_units) {
  printf("%-21s = %10.3f %-2s / %10.3f %-2s = %7.3f%%\n",
    name, tot, tot_units, period, period_units, ratio(tot * 100.0, period));
}

function getTimeStamp() {
  gts_tmp_str = $0;
  # Note:  want to match the time stamp just before the '[GC' or '[Full GC' or
  # '[CMS-' string on the line, and there may be time stamps that appear
  # earlier.  Thus there is no beginning-of-line anchor ('^') in the regexp used
  # with match().
  if (sub(/:? ? ?\[((Full )?GC|(AS)?CMS-).*/, "", gts_tmp_str) != 1) return -1.0;
  if (! match(gts_tmp_str, "[0-9]+\\.[0-9]+(e[+-][0-9]+)?$")) return -1.0;

  gts_tmp = substr(gts_tmp_str, RSTART, RLENGTH) + 0.0;
  return gts_tmp;
}

function recordStatsInternal(idx, seconds) {
  count_v[idx] += 1;
  sum_v[idx] += seconds;
  sum_of_sq_v[idx] += seconds * seconds;
  if (seconds > max_v[idx]) max_v[idx] = seconds;
}

function writePlotData(tstamp, value) {
  if (plotcolumns == 4) {
    # Column 1 = start time, 2 = duration, 3 = end time, 4 = duration.
    printf("%9.7f %9.7f %9.7f %9.7f\n", tstamp, value, tstamp + value, value);
    return;
  }
  if (plotcolumns == 2) {
    # Column 1 = start time, 2 = value.
    printf("%9.7f %9.7f\n", tstamp, value);
    return;
  }
  if (plotcolumns == 1) {
    # Column 1 = start time.
    printf("%9.7f\n", tstamp);
    return;
  }
  if (plotcolumns == 3) {
    # Column 1 = start time, 2 = duration, 3 = end time.
    printf("%9.7f %9.7f %9.7f\n", tstamp, value, tstamp + value);
    return;
  }
}

function recordStats(idx, value) {
  if (verbose) print name_v[idx] ":" NR ":" value;
  if (plot_idx < 0) {
    # Plotting disabled; record statistics.
    recordStatsInternal(idx, value);
    recordStatsInternal(idx + last_idx, value);
    if (idx < totgc_idx) recordStatsInternal(totgc_idx, value);
  } else if (idx == plot_idx || plot_idx == totgc_idx && idx < totgc_idx) {
    # Plotting enabled; skip statistics and just print a plot line.
    rs_tstamp = getTimeStamp();
    if (rs_tstamp < 0.0) rs_tstamp = ++plot_cnt;
    writePlotData(rs_tstamp, value);
  }
}

function parseHeapSizes(sizes, str) {
  sizes[0] = sizes[1] = 0.0;

  if (!match(str, heap_size_re "->")) return -1;
  sizes[0] = substr(str, RSTART, RLENGTH - 3) + 0.0;
  if (substr(str, RSTART + RLENGTH - 3, 1) == "K") {
	  sizes[0] = sizes[0] / 1024.0;
  }

  if (!match(str, "[KM]->" heap_size_re)) return -1;
  sizes[1] = substr(str, RSTART + 3, RLENGTH - 4) + 0.0;
  if (substr(str, RSTART, 1) == "K") {
	  sizes[1] = sizes[1] / 1024.0;
  }

  if (!match(str, heap_size_paren_re)) return -1;
  sizes[2] = substr(str, RSTART + 1, RLENGTH - 3) + 0.0;
  if (substr(str, RSTART + RLENGTH - 2, 1) == "K") {
	  sizes[2] = sizes[2] / 1024.0;
  }

  return 0;
}

function recordHeapKb(str) {
  if (parseHeapSizes(tmp_mb, str) < 0) return;
  recordStats(MB_a_idx, tmp_mb[0] - gen0_sizes[1]);
  # Occupancy (the before gc value is used).
  recordStats(MB_usedh_idx, tmp_mb[0]);
  # Total heap committed size.
  recordStats(MB_ch_idx, tmp_mb[2]);

  gen0_sizes[0] = tmp_mb[0];
  gen0_sizes[1] = tmp_mb[1];
  gen0_sizes[2] = tmp_mb[2];
}

function recordGen0Kb(str, allow_3_sizes) {
  # Allocation info.
  if (parseHeapSizes(tmp_mb, str) < 0) { return; }
  str = substr(str, RSTART + RLENGTH);
#  print $0;
#  print tmp_mb[0],tmp_mb[1],gen0_sizes[0],gen0_sizes[1];
  recordStats(MB_used0_idx, tmp_mb[0]);
  recordStats(MB_a_idx, tmp_mb[0] - gen0_sizes[1]);
  # Gen0 committed size.
  recordStats(MB_c0_idx, tmp_mb[2]);

  gen0_sizes[0] = tmp_mb[0];
  gen0_sizes[1] = tmp_mb[1];
  gen0_sizes[2] = tmp_mb[2];

  # If there isn't a second heap size figure (4096K->1024K) on the line,
  # promotion and occupancy info aren't available.
  if (parseHeapSizes(tmp_mb, str) < 0) return;

  # Promotion info.  Amount promoted is inferred from the last nnnK->nnnK
  # on the line, taking into account the amount collected:
  # 
  # promoted = change-in-overall-heap-occupancy - change-in-gen0-occupancy -
  #   change-in-gen1-occupancy
  #
  str = substr(str, RSTART + RLENGTH);
  if (match(str, heap_size_change_re) && allow_3_sizes) {
    # There is a 3rd heap size on the line; the 2nd one just parsed is assumed
    # to be from the old gen.  Get the 3rd one and use that for the overall
    # heap.
    gen1_sizes[0] = tmp_mb[0];
    gen1_sizes[1] = tmp_mb[1];
    gen1_sizes[2] = tmp_mb[2];
    parseHeapSizes(tmp_mb, str);
    mb_promo = tmp_mb[1] - tmp_mb[0] - (gen0_sizes[1] - gen0_sizes[0]);
    mb_promo -= (gen1_sizes[1] - gen1_sizes[0]);
  } else {
    # Only gen0 was collected.
    mb_promo = tmp_mb[1] - tmp_mb[0] - (gen0_sizes[1] - gen0_sizes[0]);
  }
  recordStats(MB_p_idx, mb_promo);
  # Occupancy (the before gc value is used).
  recordStats(MB_usedh_idx, tmp_mb[0]);
  # Total heap committed size.
  recordStats(MB_ch_idx, tmp_mb[2]);
  # Gen1 committed size.
  recordStats(MB_c1_idx, tmp_mb[2] - gen0_sizes[2]);
}

function recordParOldPhaseTime(str, phase_label, idx) {
	sub(".*" phase_label " *[,:] *", "", str);
	sub(" secs\\].*", "", str);
	recordStats(idx, str + 0.0);
	next;
}

function printInterval() {
  # No intervals if plotting.
  if (plot_idx >= 0) return;

  # Check for a time stamp.
  pi_tmp = getTimeStamp();
  if (pi_tmp < 0.0) return;

  # Update the global time stamp vars.
  if (lastFileName == FILENAME) {
    lastTimeStamp = timeStampOffset + pi_tmp;
  } else {
    if (firstTimeStamp < 0) {
      # First call of the run; initialize.
      lastTimeStamp = pi_tmp;
      firstTimeStamp = prevTimeStamp = lastTimeStamp;
    } else {
      # First call after the input file changed.
      timeStampOffset = lastTimeStamp;
      lastTimeStamp = timeStampOffset + pi_tmp;
    }
    lastFileName = FILENAME;
#     printf("%10.3f %10.6f %s %s\n", timeStampOffset, pi_tmp,
#       pi_tmp_str, FILENAME);
  }

  # Print out the statistics every timeStampDelta seconds.
  if (timeStampDelta < 0) return;
  if ((lastTimeStamp - prevTimeStamp) > timeStampDelta) {
    prevTimeStamp = lastTimeStamp;
    if ((printFirstHeader == 1) ||
    ((last_cmsRcount == 0) && (count_v[cmsRM_idx] != 0))) {
      printf("Incremental statistics at %d second intervals\n", timeStampDelta);
      printHeader();
      last_cmsRcount = count_v[cmsRM_idx];
      printFirstHeader = 0;
    }

    printf("interval=%d, time=%5.3f secs, line=%d\n",
      int((lastTimeStamp - firstTimeStamp) / timeStampDelta),
      lastTimeStamp, NR);
    for (i = 0; i < last_idx; ++i) {
      if (count_v[last_idx + i] > 0) {
	printData(last_idx + i);
      }
    }

    initIntervalVars();
  }
}

# Match CMS initial mark output from PrintGCDetails.
# 
#    [GC [1 CMS-initial-mark: 14136K(23568K)] 14216K(25680K), 0.0062443 secs]
#
#/\[GC \[1 (AS)?CMS-initial-mark: [0-9]+K\([0-9]+K\)\] [0-9]+K\([0-9]+K\), [0-9][0-9.]* secs\]/ {
# /\[1 (AS)?CMS-initial-mark: [0-9]+K\([0-9]+K\)\] [0-9]+K\([0-9]+K\), [0-9][0-9.]* secs\]/ {
#
match($0, "\\[1 (AS)?CMS-initial-mark: " cms_heap_size_re "\\] " cms_heap_report_re "\\]") {
  tString = substr($0, RSTART, RLENGTH);
  match(tString, gc_time_secs_re);
  secs = substr(tString, RSTART, RLENGTH - 5) + 0;
  recordStats(cmsIM_idx, secs);
  next;
}

# Match cms remark output from PrintGCDetails.
#[GC[dirty card accumulation, 0.0006214 secs][dirty card rescan, 0.1919700 secs] [1 CMS-remark: 10044K(16744K)] 10412K(18856K), 0.2095526 secs]
#
# /\[GC.*CMS-remark.*, [0-9][0-9.]*\ secs\]/ {
# /\[1 CMS-remark.*, [0-9][0-9.]*\ secs\]/ {
# /\[1 (AS)?CMS-remark: [0-9]+K\([0-9]+K\)\] [0-9]+K\([0-9]+K\), [0-9][0-9.]* secs\]/ {
match($0, "\\[1 (AS)?CMS-remark: " cms_heap_size_re "\\] " cms_heap_report_re "\\]") {
  tString = substr($0, RSTART, RLENGTH);
  match(tString, gc_time_secs_re);
  secs = substr(tString, RSTART, RLENGTH - 5) + 0;
  recordStats(cmsRM_idx, secs);
  # recordStats incremented the total gc count; undo that.
  count_v[totgc_idx] -= 1;
  next;
}

# Match CMS initial mark or remark output from -verbose:gc.
#
# [GC 43466K(68920K), 0.0002577 secs]
match($0, "\\[GC " cms_heap_report_re "\\]") {
  match($0, gc_time_secs_re);
  secs = substr($0, RSTART, RLENGTH - 5) + 0;
  recordStats(gen1t_idx, secs);
  # XXX - this updates the count of gen1 collections for both initial mark and
  # remark.  Would like to update it only once per cms cycle (i.e., for initial
  # mark only).  Doing the increment every other time would be more accurate,
  # but still subject to error because of aborted CMS cycles.
  next;
}

# Match cms concurrent phase output
# [CMS-concurrent-mark: 6.422/9.360 secs]
# 10820.4: [CMS-concurrent-mark: 6.422/9.360 secs]
# /\[(AS)?CMS-concurrent-(mark|preclean|sweep|reset): [0-9.]+\/[0-9.]+ secs\]/ {
$0 ~ "\\[" cms_concurrent_phase_re ": " gc_time_re "/" gc_time_secs_re "\\]" {
  match($0, cms_concurrent_phase_re ": ");	
  t_time_idx = RSTART + RLENGTH;
  tString = substr($0, RSTART, RLENGTH);
  if (match(tString, "-mark:")) {
    tIdx = cmsCM_idx;
  } else if (match(tString, "-sweep:")) {
    tIdx = cmsCS_idx;
  } else if (match(tString, "-preclean:")) {
    tIdx = cmsCP_idx;
  } else {
    tIdx = cmsCR_idx;
  }
  tString = substr($0, t_time_idx);
  match(tString, "/" gc_time_secs_re);
  secs = substr(tString, 1, RSTART - 1) + 0.0;
  recordStats(tIdx, secs);
  printInterval(); # Must do this before the getline below.

  if (match($0, "\\[(AS)?CMS" timestamp_re "\\[" cms_concurrent_phase_re)) {
    # If CMS is in the middle of a concurrent phase when System.gc() is called
    # or concurrent mode failure causes a bail out to mark-sweep,
    # the output is split across 2 lines, e.g.:
    #
    # 164.092: [Full GC 164.093: [CMS164.341: [CMS-concurrent-mark: 0.302/0.304 secs]
    # : 26221K->24397K(43704K), 0.8347158 secs] 26285K->24397K(64952K), [CMS Perm : 2794K->2794K(16384K)], 0.8350998 secs]
    #
    getline;
    tString = $0;
    tInt = sub(".*" heap_size_status_re "\\]?, ", "", tString);
    tInt += sub(" secs.*", "", tString);
    if (tInt == 2) {
      secs = tString + 0.0;
      recordStats(gen1t_idx, secs);
    }
  }
  next;
}

# Match PrintGCDetails output for Tenured or CMS full GC
# [GC [DefNew: 2048K->64K(2112K), 0.1517089 secs][Tenured: 1859K->1912K(1920K), 0.1184458 secs] 2048K->1923K(4032K), 0.2710333 secs]
#	or with time stamps
# 0.177656: [GC 0.177728: [DefNew: 2112K->0K(2176K), 0.1006331 secs]0.278442: [Tenured: 4092K->4092K(4208K), 0.1372500 secs] 4096K->4092K(6384K), 0.2385750 secs]
# 549.281: [GC 549.281: [ParNew: 14783K->14783K(14784K), 0.0000680 secs]549.281: [CMS: 275188K->136280K(290816K), 3.7791360 secs] 289972K->136280K(305600K), 3.7795440 secs]
# 
# /\[GC.*\[(DefNew|(AS)?ParNew): [0-9]+K->[0-9]+K\([0-9]+K\),.*secs\].*\[((AS)?CMS|Tenured): [0-9]+K->[0-9]+K\([0-9]+K\),.*secs\]/ {
#
# [GC [ParNew: 7812K->7812K(8128K), 0.0000310 secs][CMS (concurrent mode failure): 382515K->384858K(385024K), 0.0657172 secs] 390327K->390327K(393152K), 0.0658860 secs]

$0 ~ "\\[GC.*\\[" fw_yng_gen_re ": " heap_report_re "\\].*\\[" fw_old_gen_re ": " heap_report_re "\\]" {
  tString = $0;
  tInt = sub(".*" heap_size_status_re ", ", "", tString);
  tInt = sub(" secs.*", "", tString);
  secs = tString + 0.0;
  recordStats(gen1t_idx, secs);

  # Old gen occupancy before GC.
  tString = $0;
  tInt = sub(".*\\[" fw_old_gen_re ": ", "", tString);
  parseHeapSizes(tmp_mb, tString);
  recordStats(MB_used1_idx, tmp_mb[0]);

  # Heap occupancy before GC.
  tInt = sub(heap_report_re "\\] ", "", tString);
  parseHeapSizes(tmp_mb, tString);
  recordStats(MB_usedh_idx, tmp_mb[0]);

  printInterval();
  next;
}

# [Full GC [Tenured: 43464K->43462K(43712K), 0.0614658 secs] 63777K->63775K(64896K), [Perm : 1460K->1459K(16384K)], 0.0615839 secs]
# 
# 0.502: [Full GC 0.502: [Tenured: 43464K->43462K(43712K), 0.0724391 secs] 63777K->63775K(64896K), [Perm : 1460K->1459K(16384K)], 0.0725792 secs]

$0 ~ full_gc_re timestamp_re ".*\\[" fw_old_gen_re ": " heap_report_re "\\] " heap_size_status_re ", \\[((AS)?CMS )?Perm *: " heap_size_status_re "\\], " gc_time_secs_re "\\]" {
  tString = $0;
  tInt = sub(".*" heap_size_status_re "\\], ", "", tString);
  tInt = sub(" secs.*", "", tString);
  secs = tString + 0.0;
  recordStats(gen1t_idx, secs);

  # Old gen occupancy before GC.
  tString = $0;
  tInt = sub(".*\\[" fw_old_gen_re ": ", "", tString);
  parseHeapSizes(tmp_mb, tString);
  recordStats(MB_used1_idx, tmp_mb[0]);

  # Heap occupancy before GC.
  tInt = sub(heap_report_re "\\] ", "", tString);
  parseHeapSizes(tmp_mb, tString);
  recordStats(MB_usedh_idx, tmp_mb[0]);

  printInterval();
  next;
}

# Full GC (System.gc()) w/CMS when the perm gen is *not* being collected.
# 
#    [Full GC [ParNew: 161K->238K(12288K), 0.0014651 secs] 161K->238K(61440K), 0.0015972 secs]
#    0.178: [Full GC 0.178: [ParNew: 161K->238K(12288K), 0.0014651 secs] 161K->238K(61440K), 0.0015972 secs]
$0 ~ full_gc_re timestamp_re ".*\\[" fw_yng_gen_re ": " heap_report_re "\\] " heap_report_re "\\]" {
  match($0, ".*" heap_size_status_re ", ");
  tString = substr($0, RSTART + RLENGTH);
  tInt = sub(" secs.*", "", tString);
  secs = tString + 0.0;
  recordStats(gen1t_idx, secs);
  printInterval();
  next;
}

# Match PrintGCDetails output for Train incremental GCs.
/\[GC.*\[(Def|Par)New: [0-9]+K->[0-9]+K\([0-9]+K\),.*secs\].*\[Train: [0-9]+K->[0-9]+K\([0-9]+K\),.*secs\]/ {
  # Young gen part.
  tString = $0;
  tInt = sub(/ secs.*/, "", tString);
  tInt = sub(".*" heap_size_status_re "\\], ", "", tString);
  secs = tString + 0.0;
  recordStats(gen0t_idx, secs);

  # Train incremental part.
  tString = $0;
  tInt = sub(".*Train: [^,]+, ", "", tString);
  tInt = sub(" secs.*", "", tString);
  secs = tString + 0.0;
  if (plot_idx < 0) {
    # Skip the update of the totgc numbers, that was handled above.
    recordStatsInternal(gen1i_idx, secs);
    recordStatsInternal(gen1i_idx + last_idx, secs);
  } else if (plot_idx == gen1i_idx) {
    recordStats(gen1i_idx, secs);
  }
  recordGen0Kb($0, 1);
  printInterval();
  next;
}

# Match PrintGCDetails output for Train Full GC.
/.*\[Train MSC: [0-9]+K->[0-9]+K\([0-9]+K\),.*secs\]/ {
  # Get the last number of seconds on the line.
  tString = $0;
  tInt = sub(".*" heap_size_status_re ", ", "", tString);
  tInt = sub(" secs.*", "", tString);
  secs = tString + 0.0;
  recordStats(gen1t_idx, secs);

  printInterval();
  next;
}

# Match PrintGCDetails output for DefNew or ParNew
#[GC [DefNew: 2880K->63K(2944K), 0.4626167 secs] 16999K->16999K(26480K), 0.4627703 secs]
#	or with time stamps
# 0.431984: [GC 0.432051: [DefNew: 2112K->0K(2176K), 0.0911555 secs] 6204K->6201K(9000K), 0.0912899 secs]
# /\[GC.*\[(DefNew|(AS)?ParNew): [0-9]+K->[0-9]+K\([0-9]+K\),.*secs\] [0-9]+K->[0-9]+K\([0-9]+K\),.*secs\]/ {
$0 ~ "\\[GC " timestamp_re "\\[" fw_yng_gen_re ": " heap_report_re "\\] " heap_report_re "\\]" {
  # The first time on the line is for DefNew/ParNew gc work only.
  match($0, gc_time_secs_re);
  secs = substr($0, RSTART, RLENGTH - 5) + 0;
  tString = substr($0, RSTART + RLENGTH);

  if (plot_idx < 0) {
    # Skip the update of the totgc numbers, that will be handled below.
    recordStatsInternal(gen0c_idx, secs);
    recordStatsInternal(gen0c_idx + last_idx, secs);
  } else if (plot_idx == gen0c_idx) {
    recordStats(gen0c_idx, secs);
  }

  # The second time is the total time, which includes prologue, epilogue and
  # safepoint time.
  match(tString, gc_time_secs_re);
  secs = substr(tString, RSTART, RLENGTH - 5) + 0;
  recordStats(gen0t_idx, secs);

  recordGen0Kb($0, 0);
  printInterval();
  next;
}

# 17.438: [Full GC [PSYoungGen: 48K->0K(9536K)] [PSOldGen: 173K->179K(87424K)] 221K->179K(96960K) [PSPermGen: 1928K->1928K(16384K)], 0.0824100 secs]
# 17.438: [Full GC [PSYoungGen: 48K->0K(9536K)] [ParOldGen: 173K->179K(87424K)] 221K->179K(96960K) [PSPermGen: 1928K->1928K(16384K)], 0.0824100 secs]
$0 ~ full_gc_re "\\[PSYoungGen: +" heap_size_status_re "\\] \\[(PS|Par)OldGen: +" heap_size_status_re "\\] " heap_size_status_re " \\[PSPermGen: +" heap_size_status_re "\\], " gc_time_secs_re "\\]" {
  match($0, gc_time_secs_re);
  secs = substr($0, RSTART, RLENGTH - 5) + 0;
  recordStats(gen1t_idx, secs);

  # Old gen occupancy before GC.
  tString = $0;
  tInt = sub(".*\\[(PS|Par)OldGen: +", "", tString);
  parseHeapSizes(tmp_mb, tString);
  recordStats(MB_used1_idx, tmp_mb[0]);

  # Heap occupancy before GC.
  tInt = sub(heap_size_status_re "\\] ", "", tString);
  parseHeapSizes(tmp_mb, tString);
  recordStats(MB_usedh_idx, tmp_mb[0]);

  printInterval();
  next;
}

# [GC [PSYoungGen: 1070K->78K(1091K)] 3513K->2521K(4612K), 0.2177698 secs]
$0 ~ "\\[GC(--)? \\[PSYoungGen: +" heap_size_status_re "\\] " heap_report_re "\\]" {
  match($0, gc_time_secs_re);
  secs = substr($0, RSTART, RLENGTH - 5) + 0;
  recordStats(gen0t_idx, secs);

  recordGen0Kb($0, 0);
  printInterval();
  next;
}

#	[GC[0: 511K->228K(1984K)], 0.0087278 secs]
# or	[GC[1: 308K->230K(1984K)], 0.0212333 secs]
# or 	[GC[0: 8313K->8313K(8944K)][1: 8313K->8313K(8944K)], 0.2044176 secs]
# but this only handles generations 0 and 1.
#/\[GC\[.*\], [0-9][0-9.]* secs\]/ {
/\[GC.*\[.*\], [0-9][0-9.]* secs\]/ {
  tString = $0;
  tInt = sub(".*, ", "", tString);
  tInt = sub(" secs.*", "", tString);
  secs = tString + 0.0;
  # If a line is for generation 1, we give it all the time.
  # If it is just for generation 0, we give that generation the time.
  if ($0 ~ /\[1: /) {
    recordStats(gen1t_idx, secs);
  } else if ($0 ~ /\[0: /) {
    recordStats(gen0c_idx, secs);
    recordGen0Kb($0, 0);
  }
  printInterval();
  next;
}

# Match Garbage-First output:
#    [GC pause (young), 0.0082 secs]
# or [GC pause (partial), 0.082 secs]
# or [GC pause (young) (initial mark), 0.082 secs]
# or [GC remark, 0.082 secs]
# or [GC cleanup 11M->11M(25M), 0.126 secs]
# /\[GC.*, [0-9][0-9.]* secs\]/ {
# $0 ~ g1_stw_re {
$0 ~ g1_stw_re {
  match($0, gc_time_secs_re);
  secs = substr($0, RSTART, RLENGTH - 5) + 0;
  recordStats(gen1t_idx, secs);
  printInterval();
  next;
}

# Match -verbose:gc and pre-GC-interface output
#    [GC 17648K->12496K(31744K), 0.0800696 secs]
#    [GC-- 17648K->12496K(31744K), 0.0800696 secs]
#    [ParNew 17648K->12496K(31744K), 0.0800696 secs]
# /\[(GC(--)?|(AS)?ParNew) [0-9]+K->[0-9]+K\([0-9]+K\), [0-9][0-9.]* secs\]/ {
$0 ~ "\\[(GC(--)?|" parnew_gen_re ") " heap_report_re "\\]" {
  match($0, gc_time_secs_re);
  secs = substr($0, RSTART, RLENGTH - 5) + 0;
  recordStats(gen0c_idx, secs);
  recordHeapKb($0);
  printInterval();
  next;
}

# Match -verbose:gc and pre-GC-interface output
#    [Full GC 14538K->535K(31744K), 0.1335093 secs]
$0 ~ full_gc_re heap_report_re "\\]" {
  match($0, gc_time_secs_re);
  secs = substr($0, RSTART, RLENGTH - 5) + 0;
  recordStats(gen1t_idx, secs);
  recordHeapKb($0);
  printInterval();
  next;
}

# Parallel Old Gen phases.
# 0.547: [par marking phase, 0.0400133 secs]
# 0.547: [par marking main, 0.0400133 secs]
# 0.547: [par marking flush, 0.0400133 secs]
# 0.587: [summary phase, 0.0022902 secs]
# 0.590: [adjust roots, 0.0056697 secs]
# 0.596: [compact perm gen, 0.1242983 secs]
# 0.720: [draining task setup , 0.0031352 secs]
# -or-
# 0.720: [drain task setup, 0.0031352 secs]
# 0.724: [dense prefix task setup , 0.0000029 secs]
# 0.724: [steal task setup , 0.0000227 secs]
# 0.724: [par compact, 0.0154057 secs]
# 0.739: [post compact, 0.0009566 secs]
/\[pre compact *[,:] *[0-9][0-9.]* secs\]/ {
	recordParOldPhaseTime($0, "pre compact", PO_precomp_idx);
}
/\[(par )?marking phase *[,:] *[0-9][0-9.]* secs\]/ {
	recordParOldPhaseTime($0, "(par )?marking phase", PO_marking_idx);
}
/\[par mark *[,:] *[0-9][0-9.]* secs\]/ {
	recordParOldPhaseTime($0, "par mark", PO_parmark_idx);
}
/\[marking flush *[,:] *[0-9][0-9.]* secs\]/ {
	recordParOldPhaseTime($0, "marking flush", PO_mark_flush_idx);
}
/\[summary phase *[,:] *[0-9][0-9.]* secs\]/ {
	recordParOldPhaseTime($0, "summary phase", PO_summary_idx);
}
/\[adjust roots *[,:] *[0-9][0-9.]* secs\]/ {
	recordParOldPhaseTime($0, "adjust roots", PO_adjroots_idx);
}
/\[compact perm gen *[,:] *[0-9][0-9.]* secs\]/ {
	recordParOldPhaseTime($0, "compact perm gen", PO_permgen_idx);
}
/\[compaction phase *[,:] *[0-9][0-9.]* secs\]/ {
	recordParOldPhaseTime($0, "compaction phase", PO_compact_idx);
}
/\[drain(ing)? task setup *[,:] *[0-9][0-9.]* secs\]/ {
	recordParOldPhaseTime($0, "drain(ing)? task setup", PO_drain_ts_idx);
}
/\[dense prefix task setup *[,:] *[0-9][0-9.]* secs\]/ {
	recordParOldPhaseTime($0, "dense prefix task setup", PO_dpre_ts_idx);
}
/\[steal task setup *[,:] *[0-9][0-9.]* secs\]/ {
	recordParOldPhaseTime($0, "steal task setup", PO_steal_ts_idx);
}
/\[par compact *[,:] *[0-9][0-9.]* secs\]/ {
	recordParOldPhaseTime($0, "par compact", PO_parcomp_idx);
}
/\[deferred updates *[,:] *[0-9][0-9.]* secs\]/ {
	recordParOldPhaseTime($0, "deferred updates", PO_deferred_idx);
}
/\[post compact *[,:] *[0-9][0-9.]* secs\]/ {
	recordParOldPhaseTime($0, "post compact", PO_postcomp_idx);
}

# Match output from -XX:+TraceGCApplicationStoppedTime.
/Total time for which application threads were stopped: [0-9][0-9.]* seconds/ {
	match($0, "were stopped: [0-9][0-9.]* seconds");
	secs = substr($0, RSTART + 14, RLENGTH - 14 - 8) + 0;
	recordStats(safept_idx, secs);
	next;
}

# Match output from -XX:+TraceGCApplicationConcurrentTime.
/Application time:[	 ]+[0-9][0-9.]* seconds/ {
	match($0, "Application time:[	 ]+[0-9][0-9.]* seconds");
	secs = substr($0, RSTART + 18, RLENGTH - 18 - 8) + 0;
	recordStats(apptime_idx, secs);
	next;
}

# Match +TraceGen*Time output
# $1           $2 $3         $4     $5   $6      $7
/\[Accumulated GC generation [0-9]+ time [0-9.]+ secs\]/ {
  if ($4 == 0) {
    gc0caccum = $6 + 0;
  } else if ($4 == 1) {
    gc1taccum = $6 + 0;
  } else {
    printf("Accumulated GC generation out of bounds\n");
  }
  next;
}

# BEA JRockit GC times (very basic).
# Java(TM) 2 Runtime Environment, Standard Edition (build 1.5.0_04-b05)
# BEA JRockit(R) (build R26.1.0-22-54592-1.5.0_04-20051213-1629-solaris-sparcv9, )
# 
# [memory ] <s>-<end>: GC <before>K-><after>K (<heap>K), <pause> ms
# [memory ] <s/start> - start time of collection (seconds since jvm start)
# [memory ] <end>     - end time of collection (seconds since jvm start)
# [memory ] <before>  - memory used by objects before collection (KB)
# [memory ] <after>   - memory used by objects after collection (KB)
# [memory ] <heap>    - size of heap after collection (KB)
# [memory ] <pause>   - total pause time during collection (milliseconds)
#
# [memory ] 14.229-16.647: GC 1572864K->718K (10485760K), 2418.000 ms
# [memory ] 133.299-133.568: GC 10485760K->762425K (10485760K), 269.000 ms

match($0, "\\[memory ?\\] " timestamp_range_re "GC " heap_size_status_re ", " gc_time_ms_re) {
  match($0, gc_time_ms_re);
  secs = substr($0, RSTART, RLENGTH - 3) / 1000.0;
  recordStats(gen1t_idx, secs);
  recordHeapKb($0);
  # printInterval();
  next;
}

# EVM allocation info.
#
# Starting GC at Tue Nov 12 10:44:23 2002; suspending threads.
# Gen[0](semi-spaces): size=12Mb(50% overhead), free=0kb, maxAlloc=0kb.
/Starting GC at .*; suspending threads/ {
  evm_last_was_starting_gc = 1;
  next;
}

evm_last_was_starting_gc && \
$0 ~ /Gen\[0\]\([a-z-]+\): size=[0-9]+Mb.*, free=[0-9]+kb,/ {
  evm_last_was_starting_gc = 0;
  match($0, "size=[0-9]+Mb");
  tString = substr($0, RSTART + 5, RLENGTH - 7);
  tmp_size = tString * 512;	# * 1024 / 2:  the size includes both semispaces
  match($0, "free=[0-9]+kb");
  tString = substr($0, RSTART + 5, RLENGTH - 7);
  tmp_free = tString + 0;
  recordStats(MB_a_idx, (tmp_size - tmp_free) / 1024);
  next;
}

# EVM promotion info
# 
# Gen0(semi-spaces)-GC #2030 tenure-thresh=0 42ms 0%->100% free, promoted 46712 obj's/1978kb
# /Gen0\([a-z-]+\)-GC.* promoted / {
/% free, promoted [0-9]+ obj.s\/[0-9]+kb/ {
  tString = $0;
  match($0, "obj.s/[0-9]+kb");
  tString = substr($0, RSTART + 6, RLENGTH - 8);
  kb_promo = tString + 0;
  recordStats(MB_p_idx, kb_promo / 1024.0);
  next;
}

function recordGCPauseEVM(idx) {
  evm_last_was_starting_gc = 0;
  match($0, "in [0-9]+ ms:");
  tString = substr($0, RSTART + 3, RLENGTH - 7);
  recordStats(idx, tString / 1000.0);

  # Record committed and used stats for young gen collections.
  if (idx == gen0t_idx && match($0, "ms: \\([0-9]+[MmKk][Bb],")) {
    tString = substr($0, RSTART + 5, RLENGTH - 8);
    evm_units = tolower(substr($0, RSTART + RLENGTH - 3, 2));
    evm_factor = evm_units == "kb" ? 1024 : 1;
    evm_val = tString + 0;
    recordStats(MB_ch_idx, tString / evm_factor);
    if (match($0, ", [0-9]+% free\\)")) {
      tString = substr($0, RSTART + 2, RLENGTH - 7);
      evm_val = evm_val * (100 - tString) / 100;
      recordStats(MB_usedh_idx, evm_val / evm_factor);
    }
  }

  # Application time.
  if (match($0, "\\[application [0-9]+ ms")) {
    tString = substr($0, RSTART + 13, RLENGTH - 16);
    recordStats(apptime_idx, tString / 1000.0);
  }
}

# EVM output with -verbose:gc -verbose:gc
# 
# GC[0] in 50 ms: (656Mb, 80% free) -> (656Mb, 80% free) [application 353 ms  requested 6 words]
# GC[1] in 3963 ms: (656Mb, 0% free) -> (656Mb, 81% free) [application 380 ms  requested 28 words]
# GC[1: initial mark] in 84 ms: (656Mb, 97% free) -> (656Mb, 97% free) [application 65 ms  requested 0 words]
# GC[1: remark] in 36 ms: (656Mb, 93% free) -> (656Mb, 93% free) [application 241 ms  requested 0 words]
# GC[1: resize heap] in 0 ms: (656Mb, 97% free) -> (656Mb, 97% free) [application 213 ms  requested 0 words]
/GC\[0\] in [0-9]+ ms: / {
  recordGCPauseEVM(gen0t_idx);
  printInterval();
  next;
}

/GC\[1\] in [0-9]+ ms: / {
  recordGCPauseEVM(gen1t_idx);
  next;
}

/GC\[1: initial mark\] in [0-9]+ ms: / {
  recordGCPauseEVM(cmsIM_idx);
  next;
}

/GC\[1: remark\] in [0-9]+ ms: / {
  recordGCPauseEVM(cmsRM_idx);
  next;
}

/GC\[1: resize heap\] in [0-9]+ ms: / {
  recordGCPauseEVM(cmsRS_idx);
  next;
}

END {
  # No summary stats if plotting.
  if (plot_idx >= 0) exit(0);

  if (interval >= 0) print "";

  printHeader();
  for (i = 0; i < last_idx; ++i) {
    if (count_v[i] > 0) {
      printData(i);
    }
  }

  if (lastTimeStamp != firstTimeStamp) {
    # Elapsed time.
    tot_time = lastTimeStamp - firstTimeStamp;
    # Elapsed time scaled by cpus.
    tot_cpu_time = tot_time * cpus;
    # Sequential gc time scaled by cpus.
    seq_gc_cpu_time = sum_v[totgc_idx] * cpus;
    # Concurrent gc time (scaling not necessary).
    cms_gc_cpu_time = sum_v[cmsCM_idx] + sum_v[cmsCP_idx] + \
      sum_v[cmsCS_idx] + sum_v[cmsCR_idx];
    # Cpu time available to mutators.
    mut_cpu_time = tot_cpu_time - seq_gc_cpu_time - cms_gc_cpu_time;

    print "";
    printRate("alloc/elapsed_time",
      sum_v[MB_a_idx], "MB", tot_time, "s");
    printRate("alloc/tot_cpu_time",
      sum_v[MB_a_idx], "MB", tot_cpu_time, "s");
    printRate("alloc/mut_cpu_time",
      sum_v[MB_a_idx], "MB", mut_cpu_time, "s");
    printRate("promo/elapsed_time",
      sum_v[MB_p_idx], "MB", tot_time, "s");
    printRate("promo/gc0_time",
      sum_v[MB_p_idx], "MB", sum_v[gen0t_idx], "s");
    printPercent("gc_seq_load",
      seq_gc_cpu_time, "s", tot_cpu_time, "s");
    printPercent("gc_conc_load",
      cms_gc_cpu_time, "s", tot_cpu_time, "s");
    printPercent("gc_tot_load",
      seq_gc_cpu_time + cms_gc_cpu_time, "s", tot_cpu_time, "s");
  }

  if (gc0caccum != 0 || gc1taccum != 0) {
    genAccum = gc0caccum + gc1taccum;
    printf("Accum\t%7.3f\t\t\t%7.3f\t\t\t%7.3f\n",
	   gc0caccum, gc1taccum, genAccum);
    gc0cdelta = gc0cseconds - gc0caccum;
    gc1tdelta = gc1tseconds - gc1taccum;
    gcDelta = gcSeconds - genAccum;
    printf("Delta\t%7.3f\t\t\t%7.3f\t\t\t%7.3f\n",
	   gc0cdelta, gc1tdelta, gcDelta);
  }
}

