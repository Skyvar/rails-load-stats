#!/bin/bash

if [ ${BASH_VERSION%%.*} -lt 4 ]; then
	echo "bash version >=4 is required!"
	exit 2
fi

usage() {
	echo "$*"
	echo
        echo "usage: $0 logfile [sort-results]"
        echo "where (optional) sort-results can be:"
        echo "  2: sort by count"
        echo "  3: sort by min time"
        echo "  4: sort by max time"
        echo "  5: sort by avg time"
        echo "  6: sort by mean time"
        echo "  7: sort by sum time / percentage"
        exit 1
}

if [ $# -lt 1 ]; then
	usage "missing argument!"
fi
f=${1}
if ! [ -f $f ]; then
	usage "cannot read file $f"
fi

if [ $# -gt 1 ]; then
	sortresults=${2}
	if ! [[ $sortresults =~ ^[2-7]$ ]]; then
		usage "sort-results can be only a number from 2 to 7"
	fi
fi

# remove auxiliary files
rm -f times.* results.*

# parse input file to extract from lines like:
#
# 2020-04-01T03:17:59 [I|app|07bb6705] Processing by Katello::Api::V2::RootController#rhsm_resource_list as JSON
# ..
# 2020-04-01T03:17:59 [I|app|07bb6705] Completed 200 OK in 38ms (Views: 10.7ms | ActiveRecord: 7.3ms)
#
# relevant data: requestID, processing/completed, type of request or its rudation; in particular:
#
# 07bb6705 p Katello::Api::V2::RootController#rhsm_resource_list
# 07bb6705 c 38ms 
echo "$(date): extracting relevant data from input file '${f}'.."
grep -e Processing -e Completed $f | cut -d'|' -f3 | sed "s/\] Completed / c in /g" | sed "s/\] Processing by / p in  in /g" | awk -F " in " '{ print $1" "$3 }' | awk '{ print $1" "$2" "$3 }' > processing.completed.extracted

# process those extracted data as tripples ($req $act $typeortime) as follows:
# - if act is "p" / Processing, memorize the type of request in a "requests" hash
# - if act is "c" / Completed, fetch from "requests" hash the type and append the time (without "ms") to the relevant file
echo "$(date): processing the extracted data (this can take a while).."
declare -A requests
cat processing.completed.extracted | while read req act typeortime; do
	if [ "$act" == "p" ]; then
		requests[${req}]="${typeortime}"
	else
		type=${requests[${req}]}
		unset requests[${req}]
		# if $type is empty, we didnt hash the request that was logged in a previous (missing) logfile - ignore this
		if [ -n "${type}" ]; then
			echo ${typeortime%ms} >> times.${type}
		fi
	fi
done
rm -f processing.completed.extracted

# each file times.${type} now contains response times of requests of the type ${type}; let do some stats over them
# first, find overall number of requests and their duration and print it to results.summary file
echo "$(date): summarizing stats.."
read sumall countall < <(cat times.* | awk '{ sum+=$1; c+=1 } END { print sum" "c }')
echo "there were $countall requests taking $sumall ms (i.e. $(echo $sumall | awk '{ printf "%.2f", $1/3600000 }') hours, i.e. $(echo $sumall | awk '{ printf "%.2f", $1/3600000/24 }') days) in summary" > results.summary
echo >> results.summary

# for each request type, find basic stats and print it to other results.* files
echo -e "type\t\t\t\t\t\tcount\tmin\tmax\tavg\tmean\tsum\t\tpercentage" > results.header
echo "--------------------------------------------------------------------------------------------------------------------" >> results.header
spaces="                                                  "
for type in $(ls times.* -1 | cut -d'.' -f2); do
        outtype=${type##*::}
        len=${#outtype}
        if [ $len -gt 47 ]; then
                outtype="..${outtype:(-45)}"
        else
                outtype="${outtype}${spaces:0:$((47-len))}"
        fi
        sort -n times.${type} > aux; mv -f aux times.${type}
        read sum count < <(cat times.${type} | awk '{ sum+=$1; c+=1 } END { print sum" "c }')
        min=$(head -n1 times.${type})
        max=$(tail -n1 times.${type})
        avg=$((sum/count))
        mean=$(head -n $(((count+1)/2)) times.${type} | tail -n1) # technically, for odd $count, this is not statistical term of mean, but let get over it for now
        percents=$(echo "$sum $sumall" | awk '{ printf "%.2f %", 100*$1/$2 }')
        if [ $sum -lt 10000000 ]; then
                sum="${sum}\t"
        fi
        echo -e "${outtype}\t${count}\t${min}\t${max}\t${avg}\t${mean}\t${sum}\t${percents}" >> results.table
done

echo > results.footer
echo "results are in results.* files, individual requests per each type are in times.* files" >> results.footer

# now, print all results.* files to stdout; if table should be sorted, sort it
echo
for i in summary header table footer; do
	if [ "$i" == "table" -a "$sortresults" ]; then
		cmd="sort -nrk ${sortresults}"
	else
		cmd="cat"
	fi
	$cmd results.${i}
done
