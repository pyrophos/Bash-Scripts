#!/usr/bin/nawk -f

# Usage:  CompareGCStats file1 file2
#
# where file1 and file2 are the output from PrintGCstats runs.

BEGIN {
  # Keep these in sync with PrintGCStats.
  i = 0;
  name_v[i++]	= "gen0(s)";
  name_v[i++]	= "gen0t(s)";
  name_v[i++]	= "gen1i(s)";
  name_v[i++]	= "gen1t(s)";
  name_v[i++]	= "cmsIM(s)";
  name_v[i++]	= "cmsRM(s)";
  name_v[i++]	= "cmsRS(s)";
  name_v[i++]	= "GC(s)";
  name_v[i++]	= "cmsCM(s)";
  name_v[i++]	= "cmsCP(s)";
  name_v[i++]	= "cmsCS(s)";
  name_v[i++]	= "cmsCR(s)";
  name_v[i++]	= "alloc(MB)";
  name_v[i++]	= "promo(MB)";
  name_v[i++]	= "used0(MB)";
  name_v[i++]	= "used1(MB)";
  name_v[i++]	= "used(MB)";
  name_v[i++]	= "commit0(MB)";
  name_v[i++]	= "commit1(MB)";
  name_v[i++]	= "commit(MB)";
  name_v[i++]	= "safept(s)";
  name_v[i++]	= "apptime(s)";
  # Par Old phases from PrintParallelOldGCPhaseTimes.
  name_v[i++]	= "precomp(s)";
  name_v[i++]	= "marking(s)";
  name_v[i++]	= "parmark(s)";
  name_v[i++]	= "mark-f(s)";
  name_v[i++]	= "summary(s)";
  name_v[i++]	= "adjroots(s)";
  name_v[i++]	= "permgen(s)";
  name_v[i++]	= "compact(s)";
  name_v[i++]	= "drain_ts(s)";
  name_v[i++]	= "dpre_ts(s)";
  name_v[i++]	= "steal_ts(s)";
  name_v[i++]	= "parcomp(s)";
  name_v[i++]	= "deferred(s)";
  name_v[i++]	= "postcomp(s)";
  last_basic_idx	= i;
  name_v[i++]	= "alloc/elapsed_time";
  name_v[i++]	= "alloc/tot_cpu_time";
  name_v[i++]	= "alloc/mut_cpu_time";
  name_v[i++]	= "promo/elapsed_time";
  name_v[i++]	= "promo/gc0_time";
  last_rate_idx	= i;
  name_v[i++]	= "gc_seq_load";
  name_v[i++]	= "gc_conc_load";
  name_v[i++]	= "gc_tot_load";
  last_idx	= i;

  headfmt = "%-11s" "  %7s"     "  %13s"    "  %12s"    "  %12s"    "  %9s"   "\n";
  datafmt = "%-11s" "  %7.3f%%" " %13.3f%%" " %12.5f%%" " %12.3f%%" " %9.4f%%""\n";
  ratefmt = " %7.3f%%\n"

  file_num	= -1;
  prev_line_idx = last_idx;
  initarrays(0);
  initarrays(1);
}

function initarrays(fileno) {
  for (ia_idx = 0; ia_idx < last_idx; ++ia_idx) {
    filename_v[fileno] = FILENAME;
    line_v[fileno, ia_idx] = "";
    count_v[fileno, ia_idx] = 0;
    sum_v[fileno, ia_idx] = 0.0;
    mean_v[fileno, ia_idx] = 0.0;
    max_v[fileno, ia_idx] = 0.0;
    std_dev_v[fileno, ia_idx] = 0.0;
  }
}

function percent_change(orig, new) {
	if (orig == 0.0 || new == 0.0) return 0.0;
	return (new - orig) * 100.0 / orig;
}

function compare_basic(idx) {
	printf(datafmt, " ",
	       percent_change(count_v[0, idx], count_v[1, idx]),
	       percent_change(sum_v[0, idx], sum_v[1, idx]),
	       percent_change(mean_v[0, idx], mean_v[1, idx]),
	       percent_change(max_v[0, idx], max_v[1, idx]),
	       percent_change(std_dev_v[0, idx], std_dev_v[1, idx]));
}

function record_basic_line(line, idx, pos) {
	line_v[file_num, idx] = line;
	count_v[file_num, idx] = $2 + 0.0;
	sum_v[file_num, idx] = $3 + 0.0;
	mean_v[file_num, idx] = $4 + 0.0;
	max_v[file_num, idx] = $5 + 0.0;
	std_dev_v[file_num, idx] = $6 + 0.0;
}

function record_rate_line(line, idx, pos) {
	line_v[file_num, idx] = line;
	sum_v[file_num, idx] = $(NF - 1) + 0.0;
}

function record_load_line(line, idx, pos) {
	line_v[file_num, idx] = line;
	tmpstr = $NF;
	sub("%", "", tmpstr);
	sum_v[file_num, idx] = tmpstr + 0.0;
}

function make_zero_line(str) {
	mzl_label = str;
	sub(" .*$", "", mzl_label);
	mzl_tmp = str;
	sub("^[^ ]+", "", mzl_tmp);
	gsub("[0-9]", "0", mzl_tmp);
	return mzl_label mzl_tmp;
}

function compare() {
	printf("%s vs. %s\n", filename_v[0], filename_v[1]);
	printf(headfmt, "what", "count", "total", "mean", "max", "stddev");
	for (c_idx = 0; c_idx < last_idx; ++c_idx) {
		if (line_v[0, c_idx] != "" || line_v[1, c_idx] != "") {
			if (c_idx == last_basic_idx) print "";
			if (line_v[0, c_idx] == "") {
				line_v[0, c_idx] = \
					make_zero_line(line_v[1, c_idx]);
			} else if (line_v[1, c_idx] == "") {
				line_v[1, c_idx] = \
					make_zero_line(line_v[0, c_idx]);
			}
			print line_v[0, c_idx];
			printf("%s", line_v[1, c_idx]);	# No newline.
			if (c_idx < last_basic_idx) {
				print "";
				compare_basic(c_idx);
			} else if (c_idx < last_rate_idx) {
				printf(ratefmt, 
				       percent_change(sum_v[0, c_idx],
						      sum_v[1, c_idx]));
			} else {
				printf(ratefmt,
				       sum_v[1, c_idx] - sum_v[0, c_idx]);
			}
		}
	}
}

{
	for (cur_line_idx = 0; cur_line_idx < last_idx; ++cur_line_idx) {
		pos = index($0, name_v[cur_line_idx]);
		if (pos > 0) {
			if (cur_line_idx <= prev_line_idx) {
				# Starting a new input set.
				if (++file_num == 2) {
					compare();
					print "";
					--file_num;
				}
				initarrays(file_num);
			}
			if (cur_line_idx < last_basic_idx) {
				record_basic_line($0, cur_line_idx, pos);
			} else if (cur_line_idx < last_rate_idx) {
				record_rate_line($0, cur_line_idx, pos);
			} else {
				record_load_line($0, cur_line_idx, pos);
			}
			prev_line_idx = cur_line_idx;
			continue;
		}
	}
}

END { compare(); }

