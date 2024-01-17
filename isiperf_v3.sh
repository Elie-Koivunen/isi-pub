#!/bin/bash

# This version of isiperf is meant for clusters running OneFS v7 or v8.

# isiperf_v3.sh
SCRIPT_VER="07.06.2016"
LOCATION="$( cd "$( dirname "$0" )" && pwd )"
##############################################
##
# Usage and command input
##
usage()
{
echo ""
	echo "Usage: `basename $0` [-i iterations] [-e interval] [-r repeat] -d for debug [-g gcore] -h for help"
	echo "  -i : Number of Iterations to run the Script for (required)"
	echo "  -e : isi statistics refresh interval per iteration in seconds (required)"
	echo "  -r : Number of times isi statistics repeats per iteration (required)"
	echo "  -d : Enable debug output to help monitor the progress of `basename $0`"
	echo "  -g : Collect a gcore of process(s) specified, comma separated (ie lwio,lsass,netlogon,srvsvc,nfs,mountd)"
	echo "  -w : Collect hangdumps before collecting stats"
	echo "  -z : Force stop a previously or long running `basename $0`"
	echo "  -h : Print this help"
	echo "  -v : Print version"
	echo ""
	echo "  EXAMPLES"
	echo ""
	echo "  Standard 10 minute run of performance data collection:"
	echo "   `basename $0` -i 10 -e 5 -r 12 -d"
	echo ""
	echo "  Collect 10 minutes of performance data along with hangdumps:"
	echo "    `basename $0` -i 10 -e 5 -r 12 -d -w"
	echo ""
	echo "  Collect 5 minutes of performance data along with lwio gcores:"
	echo "    `basename $0` -i 5 -e 5 -r 12 -d -g lwio"
	echo ""
	echo "  Collect 1 hour of performance data along with hangdumps and lwio, lsass, srvsvc, nfs, mountd, and netlogon gcores:"
	echo "    `basename $0` -i 60 -e 5 -r 12 -d -w -g lwio,lsass,srvsvc,netlogon,nfs,mountd"
	echo ""
	echo "  When Statistic Collection is done, the output file will be"
	echo "  located in $LOCATION/"
	echo ""
	echo ""
	exit
}
##
##############################################


##############################################
##
# Stop previous running versions of this script
##
kill_script()
{
	echo "Preparing to stop all previous running `basename $0` jobs."
	kill $(ps aux | grep "`basename $0`" | grep "i " | grep "e " | grep "r " |awk '{print $2}')
	echo $(ps aux | grep "`basename $0`" | grep "i " | grep "e " | grep "r ")
	echo ""
	echo "`basename $0` has been stopped; the isi statistics commands are still running and will"
	echo "complete shortly based on the interval and repeat options defined during the original"
	echo "statistic run.  When isi statistics is done, the incomplete data set that was collected"
	echo "before the script was stopped is located in $LOCATION"
	echo "please remove the directory before restarting another Statistic Collection."
	echo ""
	echo "The processes that will be stopping shortly are can be seen by running the following:"
	echo "ps aux | grep \"isi statistics\""
	echo ""
	exit
}
##
##############################################

##############################################
##
#Collect input from command line
##
OPTS=$1
if [ -z $OPTS ]; then OPTS='-h'; fi
if [ $OPTS = '-h' ]; then usage; fi
if [ $OPTS = '-z' ]; then kill_script; fi

while getopts i:e:r:dg:w:v opt; do
	case "${opt}"
	in
		i) STATS_ITERATIONS=${OPTARG};;
		e) STATS_INTERVAL=${OPTARG};;
		r) STATS_REPEAT=${OPTARG};;
		d) STATS_DEBUG="true";;
		g) STATS_GCORE=${OPTARG}
			IFS=',' read -ra ADDR <<< "$STATS_GCORE"
			for i in "${ADDR[@]}"; do
				if [ $i != "lwio" ] && [ $i != "lsass" ] && [ $i != "srvsvc" ] && [ $i != "netlogon" ] && [ $i != "lwreg" ] && [ $i != "lwsmd" ] && [ $i != "nfs" ] && [ $i != "mountd" ]; then
					echo ""
					echo "ERROR:"
					echo "The valid options for -g gcore are lwio, lsass, srvsvc, nfs (7.2.x+), mountd (<7.2.x) or netlogon; they can be combined with a comma. (ie lwio,lsass,nfs)"
					echo ""
					usage
				else
					CHECK_STATS_GCORE="true"
				fi
			done
			;;
		w) ISIHANG_DUMP="true";;
		v) echo "Version: $SCRIPT_VER";exit 1;;
		\?)
			echo "Invalid option: -$OPTARG" >&2
			exit 1
			;;
		:)
			echo "Option -$OPTARG requires an argument.  Use -h for help" >&2
			exit 1
			;;
	esac
done
if [[ -z $STATS_ITERATIONS ]] || [[ -z $STATS_INTERVAL ]] || [[ -z $STATS_REPEAT ]]; then usage; fi
##
##############################################

ONEFS_VERSION=`uname -r | cut -d . -f 1`
if [ $ONEFS_VERSION == "v7" ]; then ONEFS_VARIANT=`uname -r |cut -d . -f 1-2`; fi
##############################################
##
# Location of temporary work location
##
GZIP_NAME="$LOCATION/`hostname`.$(date +%m%d%Y_%H%M%S)._statistics.tar.gz"

##
# Check for /ifs/data/Isilon_Support
##
if [ ! -d /ifs/data/Isilon_Support ]; then
	echo "Path: /ifs/data/Isilon_Support does not exist; creating it."
	mkdir -p $LOCATION
fi

LOCATION="$LOCATION/$(date +%m%d%Y)_ISIPERF"
##
# Check if temporary work location exists
##
if [ -d $LOCATION ]; then
	echo "Error: $LOCATION already exists, please remove then try again."
	exit 1
else
	mkdir $LOCATION
fi
##
##############################################


##############################################
##
# Processing Calculations
##
STATS_DELAY=$((STATS_INTERVAL * STATS_REPEAT))
STATS_PROCESSING_TIME=$(((STATS_DELAY * STATS_ITERATIONS) / 60))
ARRAY_ITERATIONS=$STATS_ITERATIONS
ARRAY_DELAY=$STATS_DELAY
##
##############################################

##############################################
##
# Gcore Gathering
##
##############################################
gcore_gather()
{
	IFS=',' read -ra ADDR <<< "$STATS_GCORE"
	for i in "${ADDR[@]}"; do
		if [ $i == "lwio" ]; then
			if [ $STATS_DEBUG ]; then echo "Creating $i Cores";fi
			isi_for_array "pgrep lwio|xargs gcore -s -c $LOCATION/"'`hostname`'".lwio.$(date +%m%d%Y_%H%M%S).core"
		elif [ $i == "lsass" ]; then
			if [ $STATS_DEBUG ]; then echo "Creating $i Cores";fi
			isi_for_array "pgrep lsass|xargs gcore -s -c $LOCATION/"'`hostname`'".lsass.$(date +%m%d%Y_%H%M%S).core"
		elif [ $i == "netlogon" ]; then
			if [ $STATS_DEBUG ]; then echo "Creating $i Cores";fi
			isi_for_array "pgrep netlogon|xargs gcore -s -c $LOCATION/"'`hostname`'".netlogon.$(date +%m%d%Y_%H%M%S).core"
		elif [ $i == "srvsvc" ]; then
			if [ $STATS_DEBUG ]; then echo "Creating $i Cores";fi
			isi_for_array "pgrep srvsvc|xargs gcore -s -c $LOCATION/"'`hostname`'".srvsvc.$(date +%m%d%Y_%H%M%S).core"
		elif [ $i == "lwreg" ]; then
			if [ $STATS_DEBUG ]; then echo "Creating $i Cores";fi
			isi_for_array "pgrep lwreg|xargs gcore -s -c $LOCATION/"'`hostname`'".lwreg.$(date +%m%d%Y_%H%M%S).core"
		elif [ $i == "lwsmd" ]; then
			if [ $STATS_DEBUG ]; then echo "Creating $i Cores";fi
			isi_for_array "pgrep lwsmd|xargs gcore -s -c $LOCATION/"'`hostname`'".lwmsd.$(date +%m%d%Y_%H%M%S).core"
		elif [ $i == "nfs" ]; then
			if [ $STATS_DEBUG ]; then echo "Creating $i Cores";fi
			if [ $ONEFS_VARIANT == "v7.2" ]; then
				isi_for_array "pgrep nfs|xargs gcore -s -c $LOCATION/"'`hostname`'".nfs.$(date +%m%d%Y_%H%M%S).core"
			else
				echo "Unable to core nfs on current version (only available on v7.2.x)"
			fi
		elif [ $i == "mountd" ]; then
			if [ $STATS_DEBUG ]; then echo "Creating $i Cores";fi
			if [ $ONEFS_VARIANT == "v7.2" ]; then
				echo "Unable to core mountd on current version (only available pre v7.2.x)"
			else
				isi_for_array "pgrep mountd|xargs gcore -s -c $LOCATION/"'`hostname`'".mountd.$(date +%m%d%Y_%H%M%S).core"
			fi
		else
				echo "$STATS_GCORE"; exit 1
		fi
	done
}
hangdump_generate()
{
	echo ""
	echo "Triggering Hangdumps, this could take a few minutes.  Please note: Now that"
	echo "the Hangdump has been triggered, you cannot trigger another one for 10 minutes."
	echo "Please see KB 90156 for more information on how to gather additional Hangdumps if needed."
	echo ""
	if [ $STATS_DEBUG ]; then echo "killall -HUP isi_hangdump";fi
	isi_for_array 'killall -HUP isi_hangdump'
	while true; do
		HDLATEST=$(ls -lah /var/crash/isi_hangdump_latest.log | awk '{ print $5}')
		if [ "$HDLATEST" == "0B" ]; then
			#Buy a little more time for other nodes
			sleep 120
			echo "The hangdump process has completed."
			break
		else
			echo "Waiting on hangdump to complete."
			if [ $STATS_DEBUG ]; then echo "Size of current hangdump file: $HDLATEST";fi
			sleep 30
		fi
	done
	echo "Handump process is complete."
	echo ""
	touch $LOCATION/hang	
}
##############################################
##
# Pre-Processing work which can include sysctls that need to be
# run and also static data collection before stats are collected
# like netstat -na or lwio.log or message log
##
pre_processing()
{
	echo "Beginning Pre-Processing Work"
	isi_for_array sysctl isi.stats.client.cifs.max_clients=2048
	isi_for_array sysctl isi.stats.client.smb2.max_clients=2048
	isi_for_array sysctl isi.stats.client.nfs.max_clients=2048
	isi_for_array sysctl isi.stats.client.nfs4.max_clients=2048

	if [ $ISIHANG_DUMP ]; then
		hangdump_generate &
	fi
	echo ""

	if [ $CHECK_STATS_GCORE ]; then
		echo ""
		echo "Beginning Pre-Stat Gcore collection, this could take a few of minutes."
		gcore_gather
		echo "Pre-Stat Gcore collection is complete."
		echo ""
	fi

	echo "Pre-Processing Work Completed"
	echo ""
	echo "Collecting Statistics, this process should take around $STATS_PROCESSING_TIME minute(s)."
	echo ""
	echo "If you need to stop the Data Collection, run '`basename $0` -z' at any time."
	echo ""
}
##
##############################################


##############################################
##
# Post Processing work which will clean up any
# sysctls set in pre-processing along with
# any static data collection that needs to be
# collected stats collection.  This also calls
# the final_cleanup function
##
post_processing()
{
	echo "Beginning Post Processing Work"
	if [ $CHECK_STATS_GCORE ]; then
		echo ""
		echo "Beginning Post Stat Gcore collection, this could take a few of minutes."
		gcore_gather
		echo "Post Stat Gcore collection is complete."
		echo ""
	fi

	if [ $ISIHANG_DUMP ]; then
		echo "Ensuring hangdump is finished.. (may take at least 120 seconds since the start of script)"
		while [ ! -f $LOCATION/hang ]; do sleep 5; done
		rm -f $LOCATION/hang
		echo ""
		echo "Moving hangdump files that were collected."
		isi_for_array "find /var/crash -type f |grep 'isi_hangdump_$(date +%Y_%m_%d)*'|cut -d / -f 4|xargs -I% cp -v /var/crash/% $LOCATION/"'`hostname`'".%"
		if [ $STATS_DEBUG ]; then echo "Done copying hangdumps";fi
	fi

	isi_for_array sysctl isi.stats.client.cifs.max_clients=256
	isi_for_array sysctl isi.stats.client.smb2.max_clients=256
	isi_for_array sysctl isi.stats.client.nfs.max_clients=256
	isi_for_array sysctl isi.stats.client.nfs4.max_clients=256
	file_cleanup
}
##
##############################################


##############################################
##
# Cleanup Process that will tar up and remove the
# temporary  data and place it in the
# $LOCATION directory
##
file_cleanup()
{
	echo "Finalizing Statistic Collection"
	rm -rf $LOCATION/stats_done.tmp1
	rm -rf $LOCATION/array_done.tmp2
	tar cvzf $GZIP_NAME $LOCATION/
	rm -rf $LOCATION
	echo ""
	echo ""
	echo "Isilon Statistic Collection is complete, please upload" $GZIP_NAME
	echo ""
	echo "You can also run: isi_gather_info -n 1 --nologs -f" $GZIP_NAME
	echo ""
}
##
##############################################


##############################################
##
# Data that can be gathered from isi statistics
# this can be expanded to add any stats, they
# should have $STATUS_INTERVAL and $STATUS_REPEAT
# defined.  Try to stick to the naming format and
# make sure to add a cat entry for the stat files
# that are created
##
isi_stats()
{
	for ((a=1; a<=$STATS_ITERATIONS; a++))
	do
	start_time=$(date +%s)
####
# SMB Related Stats
####
	if [ $STATS_DEBUG ]; then echo "isi statistics pstat smb1 (break down of SMB1 calls)";fi
	{ echo $(date +%m%d%Y_%H%M%S);isi statistics pstat --protocol=smb1 --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded;} >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_pstat_smb1.out1 &

	if [ $STATS_DEBUG ]; then echo "isi statistics pstat smb2 (break down of SMB2 calls)";fi
	{ echo $(date +%m%d%Y_%H%M%S);isi statistics pstat --protocol=smb2 --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_pstat_smb2.out1 &

	if [ $STATS_DEBUG ]; then echo "isi statistics protocol smb latency (overall SMB latency per node)";fi
		if [ $ONEFS_VERSION == "v8" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics protocol list --protocols=smb1,smb2 --totalby=Node,Proto --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_smb_latency.out1 &
		fi
		if [ $ONEFS_VERSION == "v7" ]; then
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics protocol --nodes=all --protocols=smb1,smb2 --total --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_smb_latency.out1 &
		fi

	if [ $STATS_DEBUG ]; then echo "isi statistics protocol smb class latency (latency for each type of operation)";fi
		if [ $ONEFS_VERSION == "v8" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics protocol list --nodes=all --protocols=smb1,smb2 --sort=Class --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_smb_class_latency.out1 &
		fi
		if [ $ONEFS_VERSION == "v7" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics protocol --nodes=all --protocols=smb1,smb2 --orderby=Class --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_smb_class_latency.out1 &
		fi

	if [ $STATS_DEBUG ]; then echo "isi statistics protocol smb namespace_read (findfirst type work per client)";fi
		if [ $ONEFS_VERSION == "v8" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics protocol list --nodes=all --protocols=smb1,smb2 --sort=Ops --classes=namespace_read --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_smb_namespace_read.out1 &
		fi
    		if [ $ONEFS_VERSION == "v7" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics protocol --nodes=all --protocols=smb1,smb2 --orderby=Out --classes=namespace_read --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_smb_namespace_read.out1 &
		fi
	
	if [ $STATS_DEBUG ]; then echo "isi statistics query smb (breakdown of Total SMB Clients and Active Clients)";fi
		if [ $ONEFS_VERSION == "v8" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics query current list --nodes=all --keys=node.clientstats.connected.smb,node.clientstats.active.cifs,node.clientstats.active.smb2 --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; }  >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_smb_client_count.out1 &
		fi	
		if [ $ONEFS_VERSION == "v7" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics query --nodes=all --stats node.clientstats.connected.smb,node.clientstats.active.cifs,node.clientstats.active.smb2 --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; }  >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_smb_client_count.out1 &
		fi
	
	if [ $STATS_DEBUG ]; then echo "isi statistics protocols lsass (authentication requests by op coming in and external connections out)";fi
		if [ $ONEFS_VERSION == "v8" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics protocol list --nodes=all --protocols=lsass_in,lsass_out --sort=Ops --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; }  >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_lsass_by_op.out1 &
		fi
		if [ $ONEFS_VERSION == "v7" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics protocol --nodes=all --protocols=lsass_in,lsass_out --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; }  >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_lsass_by_op.out1 &
		fi

	if [ $STATS_DEBUG ]; then echo "isi statistics protocols lsass (total latency per node in and out for lsass)";fi
		if [ $ONEFS_VERSION == "v8" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics protocol list --nodes=all --protocols=lsass_in,lsass_out --totalby=Node,Proto --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; }  >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_lsass_total.out1 &
		fi
		if [ $ONEFS_VERSION == "v7" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics protocol --nodes=all --protocols=lsass_in,lsass_out --total --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; }  >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_lsass_total.out1 &
		fi
	
	if [ $STATS_DEBUG ]; then echo "isi statistics dcinfo (DC information and statistics)";fi
	{ echo $(date +%m%d%Y_%H%M%S);isi_stats_dcinfo -d 30; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_dc_info.out1 &
	
	if [ $STATS_DEBUG ]; then echo "isi statistics protocols irp (share eumeration latency)";fi
		if [ $ONEFS_VERSION == "v8" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics protocol list --nodes=all --protocols=irp --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; }  >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_share_enumeration.out1 &
		fi
		if [ $ONEFS_VERSION == "v7" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics protocol --nodes=all --protocols=irp --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; }  >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_share_enumeration.out1 &
		fi
	

####
# Disk Related stats
####
	if [ $STATS_DEBUG ]; then echo "isi statistics drive (disk drive latency)";fi
		if [ $ONEFS_VERSION == "v8" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics drive list --nodes=all --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded --long; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_disk_latency.out1 &
		fi
		if [ $ONEFS_VERSION == "v7" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics drive --nodes=all --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_disk_latency.out1 &
		fi

	if [ $STATS_DEBUG ]; then echo "isi statistics heat (top 5 paths that are used)";fi
		if [ $ONEFS_VERSION == "v8" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics heat list --limit=5 --sort=Ops,Path,Node --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded --long; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_heat.out1 &
		fi
		if [ $ONEFS_VERSION == "v7" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics heat --limit=5 --orderby=Ops,Path,Node --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_heat.out1 &
		fi
####
# General Stats
####
	if [ $STATS_DEBUG ]; then echo "isi statistics system (CPU, Memory, etc)";fi
		if [ $ONEFS_VERSION == "v8" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics system list --nodes=all --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_system.out1 &
		fi
		if [ $ONEFS_VERSION == "v7" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics system --nodes --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_system.out1 &
		fi
	
	if [ $STATS_DEBUG ]; then echo "isi statistics protocols jobd (Job Engine latency)";fi
	{ echo $(date +%m%d%Y_%H%M%S);isi statistics protocol --nodes=all --protocols=jobd --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; }  >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_job_engine.out1 &

	if [ $STATS_DEBUG ]; then echo "isi statistics protocols (Total Protocol Ops for Per Node)";fi
	{ echo $(date +%m%d%Y_%H%M%S);isi statistics protocol --nodes=all --totalby=Proto,Node --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; }  >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_protocol_per_node.out1 &

	if [ $STATS_DEBUG ]; then echo "isi statistics client (Protocol per node per client)";fi
		if [ $ONEFS_VERSION == "v8" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics client list --totalby=RemoteAddr,Node,Proto --sort=Ops --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded --long; }  >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_client_per_node_per_protocol.out1 &
		fi
		if [ $ONEFS_VERSION == "v7" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics client --totalby=RemoteAddr,Node,Proto --orderby=Ops --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; }  >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_client_per_node_per_protocol.out1 &
		fi
####
# NFS Stats
####
	if [ $STATS_DEBUG ]; then echo "isi statistics query nfs (breakdown of Total NFS Clients and Active Clients)";fi
		if [ $ONEFS_VERSION == "v8" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics query current list --nodes=all --keys=node.clientstats.connected.nfs,node.clientstats.active.nfs --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; }  >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_nfs_client_count.out1 &
		fi
		if [ $ONEFS_VERSION == "v7" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics query --nodes=all --stats node.clientstats.connected.nfs,node.clientstats.active.nfs --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; }  >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_nfs_client_count.out1 &
		fi
	
	if [ $STATS_DEBUG ]; then echo "isi statistics pstat nfs3 (break down of nfs3 calls)";fi
	{ echo $(date +%m%d%Y_%H%M%S);isi statistics pstat --protocol=nfs3 --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded;} >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_pstat_nfs3.out1 &

	if [ $STATS_DEBUG ]; then echo "isi statistics pstat nfs4 (break down of nfs4 calls)";fi
	{ echo $(date +%m%d%Y_%H%M%S);isi statistics pstat --protocol=nfs4 --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_pstat_nfs4.out1 &

	if [ $STATS_DEBUG ]; then echo "isi statistics protocol nfs latency (overall NFS latency per node)";fi
		if [ $ONEFS_VERSION == "v8" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics protocol list --nodes=all --protocols=nfs3,nfs4 --totalby=Node,Proto --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_nfs_latency.out1 &
		fi
		if [ $ONEFS_VERSION == "v7" ]; then { echo $(date +%m%d%Y_%H%M%S);isi statistics protocol --nodes=all --protocols=nfs3,nfs4 --total --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_nfs_latency.out1 &
		fi
	
	if [ $STATS_DEBUG ]; then echo "isi statistics protocol nfs class latency (latency for each type of operation)";fi
		if [ $ONEFS_VERSION == "v8" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics protocol list --nodes=all --protocols=nfs3,nfs4 --sort=Class --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_nfs_class_latency.out1 &
		fi
		if [ $ONEFS_VERSION == "v7" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics protocol --nodes=all --protocols=nfs3,nfs4 --orderby=Class --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_nfs_class_latency.out1 &
		fi
	
	if [ $STATS_DEBUG ]; then echo "isi statistics protocol nfs namespace_read (findfirst type work per client)";fi
		if [ $ONEFS_VERSION == "v8" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics protocol list --nodes=all --protocols=nfs3,nfs4 --sort=Ops --classes=namespace_read --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_nfs_namespace_read.out1 &
		fi
		if [ $ONEFS_VERSION == "v7" ]; then 
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics protocol --nodes=all --protocols=nfs3,nfs4 --orderby=Out --classes=namespace_read --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_nfs_namespace_read.out1 &
		fi
####
# HDFS Stats
####
	if [ $STATS_DEBUG ]; then echo "isi statistics pstat HDFS (break down of HDFS calls)";fi
	{ echo $(date +%m%d%Y_%H%M%S);isi statistics pstat --protocol=hdfs --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded;} >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_pstat_hdfs.out1 &

	if [ $STATS_DEBUG ]; then echo "isi statistics query hdfs (breakdown of Total HDFS Clients and Active Clients)";fi
		if [ $ONEFS_VERSION == "v8" ]; then
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics query current list --nodes=all --keys=node.clientstats.connected.hdfs,node.clientstats.active.hdfs --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; }  >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_hdfs_client_count.out1 &
		fi
		if [ $ONEFS_VERSION == "v7" ]; then
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics query --nodes=all --stats node.clientstats.connected.hdfs,node.clientstats.active.hdfs --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; }  >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_hdfs_client_count.out1 &
		fi


	if [ $STATS_DEBUG ]; then echo "isi statistics protocol hdfs latency (overall HDFS latency per node)";fi
		if [ $ONEFS_VERSION == "v8" ]; then
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics protocol list --nodes=all --protocols=hdfs --totalby=Node,Proto --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_hdfs_latency.out1 &
		fi
		if [ $ONEFS_VERSION == "v7" ]; then
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics protocol --nodes=all --protocols=hdfs --total --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_hdfs_latency.out1 &
		fi
	
	if [ $STATS_DEBUG ]; then echo "isi statistics protocol hdfs class latency (latency for each type of operation)";fi
		if [ $ONEFS_VERSION == "v8" ]; then
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics protocol list --nodes=all --protocols=hdfs --sort=Class --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_hdfs_class_latency.out1 &
		fi
		if [ $ONEFS_VERSION == "v7" ]; then
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics protocol --nodes=all --protocols=hdfs --orderby=Class --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_hdfs_class_latency.out1 &
		fi

	if [ $STATS_DEBUG ]; then echo "isi statistics protocol hdfs namespace_read (findfirst type work per client)";fi
		if [ $ONEFS_VERSION == "v8" ]; then
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics protocol list --nodes=all --protocols=hdfs --sort=Ops --classes=namespace_read --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_hdfs_namespace_read.out1 &	
		fi
		if [ $ONEFS_VERSION == "v7" ]; then
		{ echo $(date +%m%d%Y_%H%M%S);isi statistics protocol --nodes=all --protocols=hdfs --orderby=Out --classes=namespace_read --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_hdfs_namespace_read.out1 &	
		fi
####
# SyncIQ Stats
####
	if [ $STATS_DEBUG ]; then echo "isi statistics siq (SyncIQ stats)";fi
	{ echo $(date +%m%d%Y_%H%M%S);isi statistics protocol --nodes=all --protocols=siq --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_siq_stats.out1 &
####
# Network Stats
####
	#Using isi_classic for this as I haven't found a good equivalent command in 8 to get the data
	if [ $STATS_DEBUG ]; then echo "isi statistics history node.net.ext.bytes.in.rate,node.net.ext.bytes.out.rate (Network In/Out Throughput per node)";fi
	if [ $ONEFS_VERSION == "v8" ]; then 
	{ echo $(date +%m%d%Y_%H%M%S);isi_classic statistics history --begin -$STATS_DELAY --nodes=all --stats node.net.ext.bytes.in.rate,node.net.ext.bytes.out.rate -F --resolution=5 --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_network_throughput.out1 &
	fi
	if [ $ONEFS_VERSION == "v7" ]; then
	{ echo $(date +%m%d%Y_%H%M%S);isi statistics history --begin -$STATS_DELAY --nodes=all --stats node.net.ext.bytes.in.rate,node.net.ext.bytes.out.rate -F --resolution=5 --degraded; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_network_throughput.out1 &
	fi
####
# Collect some static command output
####
	if [ $STATS_DEBUG ]; then echo "Static data collection (isi status, isi sync status, etc.)";fi
	{ echo $(date +%m%d%Y_%H%M%S);isi sync job report; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_isi_sync_job_report.out1 &
	{ echo $(date +%m%d%Y_%H%M%S);isi sync job ls; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_isi_sync_job_ls.out1 &
	{ echo $(date +%m%d%Y_%H%M%S);isi status -v; } >> $LOCATION/All_Nodes.$(date +%m%d%Y_%H%M%S)_isi_status.out1 &
#######
# Step 1: Adding additional isi statistic stats
# Add additional stats here in the following format:
# if [ $STATS_DEBUG ]; then echo "isi statistics system";fi
# { echo $(date +%m%d%Y_%H%M%S);isi statistics system --nodes --interval $STATS_INTERVAL --repeat $STATS_REPEAT --degraded; } >> $LOCATION/"'`hostname`'".$(date +%m%d%Y_%H%M%S)_system.out1 &
#
# Goto Step 2.
#######
	finish_time=$(date +%s)
	sleep $STATS_DELAY

	TOTAL_STATS_DELAY=$((finish_time2 - start_time2))
	if (( $TOTAL_STATS_DELAY <= $STATS_DELAY )); then
	TOTAL_STATS_DELAY=$STATS_DELAY
	fi

	echo ""
	echo "isi statistic collection iteration: $a is done and ran for $TOTAL_STATS_DELAY seconds."
	echo ""
	echo "If you need to stop the Data Collection, run '`basename $0` -z' at any time."
	echo ""
	done
####
# Start file merger
####
	cat $LOCATION/All_Nodes.*_pstat_smb1.out1 > $LOCATION/All_Nodes.SMB.pstat_smb1.txt
	cat $LOCATION/All_Nodes.*_pstat_smb2.out1 > $LOCATION/All_Nodes.SMB.pstat_smb2.txt
	cat $LOCATION/All_Nodes.*_pstat_nfs3.out1 > $LOCATION/All_Nodes.NFS.pstat_nfs3.txt
	cat $LOCATION/All_Nodes.*_pstat_nfs4.out1 > $LOCATION/All_Nodes.NFS.pstat_nfs4.txt
	cat $LOCATION/All_Nodes.*_smb_latency.out1 > $LOCATION/All_Nodes.SMB.smb_latency.txt
	cat $LOCATION/All_Nodes.*_smb_class_latency.out1 > $LOCATION/All_Nodes.SMB.smb_class_latency.txt
	cat $LOCATION/All_Nodes.*_nfs_latency.out1 > $LOCATION/All_Nodes.NFS.nfs_latency.txt
	cat $LOCATION/All_Nodes.*_nfs_class_latency.out1 > $LOCATION/All_Nodes.NFS.nfs_class_latency.txt
	cat $LOCATION/All_Nodes.*_smb_client_count.out1 > $LOCATION/All_Nodes.SMB.smb_client_count.txt
	cat $LOCATION/All_Nodes.*_nfs_client_count.out1 > $LOCATION/All_Nodes.NFS.nfs_client_count.txt
	cat $LOCATION/All_Nodes.*_disk_latency.out1 > $LOCATION/All_Nodes.DISK.disk_latency.txt
	cat $LOCATION/All_Nodes.*_heat.out1 > $LOCATION/All_Nodes.DISK.heat.txt
	cat $LOCATION/All_Nodes.*_system.out1 > $LOCATION/All_Nodes.GENERAL.system.txt
	cat $LOCATION/All_Nodes.*_smb_namespace_read.out1 > $LOCATION/All_Nodes.SMB.smb_namespace_read.txt
	cat $LOCATION/All_Nodes.*_nfs_namespace_read.out1 > $LOCATION/All_Nodes.NFS.nfs_namespace_read.txt
	cat $LOCATION/All_Nodes.*_network_throughput.out1 > $LOCATION/All_Nodes.NETWORK.network_throughput.txt
	cat $LOCATION/All_Nodes.*_siq_stats.out1 > $LOCATION/All_Nodes.SIQ.siq_stats.txt
	cat $LOCATION/All_Nodes.*_isi_sync_job_report.out1 > $LOCATION/All_Nodes.SIQ.isi_sync_job_report.txt
	cat $LOCATION/All_Nodes.*_isi_sync_job_ls.out1 > $LOCATION/All_Nodes.SIQ.isi_sync_job_ls.txt
	cat $LOCATION/All_Nodes.*_isi_status.out1 > $LOCATION/All_Nodes.GENERAL.isi_status.txt
	cat $LOCATION/All_Nodes.*_lsass_by_op.out1 > $LOCATION/All_Nodes.SMB.lsass_by_op.txt
	cat $LOCATION/All_Nodes.*_lsass_total.out1 > $LOCATION/All_Nodes.SMB.lsass_total.txt
	cat $LOCATION/All_Nodes.*_share_enumeration.out1 > $LOCATION/All_Nodes.SMB.share_enumeration.txt
	cat $LOCATION/All_Nodes.*_dc_info.out1 > $LOCATION/All_Nodes.SMB.DC_Info.txt
	cat $LOCATION/All_Nodes.*_job_engine.out1 > $LOCATION/All_Nodes.GENERAL.job_engine.txt
	cat $LOCATION/All_Nodes.*_protocol_per_node.out1 > $LOCATION/All_Nodes.GENERAL.protocol_per_node.txt
	cat $LOCATION/All_Nodes.*_client_per_node_per_protocol.out1 > $LOCATION/All_Nodes.GENERAL.client_per_node_per_protocol.txt
	cat $LOCATION/All_Nodes.*_hdfs_latency.out1 > $LOCATION/All_Nodes.HDFS.hdfs_latency.txt
	cat $LOCATION/All_Nodes.*_hdfs_class_latency.out1 > $LOCATION/All_Nodes.HDFS.hdfs_class_latency.txt
	cat $LOCATION/All_Nodes.*_hdfs_client_count.out1 > $LOCATION/All_Nodes.HDFS.hdfs_client_count.txt
	cat $LOCATION/All_Nodes.*_hdfs_namespace_read.out1 > $LOCATION/All_Nodes.HDFS.hdfs_namespace_read.txt

#######
# Step 2: Adding additional isi statistic stats
# Add a cat statement for the stat added
# in Step 1 in the following format:
# cat $LOCATION/All_Nodes.*_system.out1 > $LOCATION/All_Nodes.system.txt
#######
	find $LOCATION -type f -iname "*.out1" -exec rm -f {} +;
	echo 1 > $LOCATION/stats_done.tmp1

	if [ -f $LOCATION/stats_done.tmp1 -a -f $LOCATION/array_done.tmp2 ]; then
		post_processing
	else
		echo "isi stats are done, waiting on isi_for_array stats to complete"
	fi
}
##
##############################################


##############################################
##
# Data that needs to be gathered by isi_for_array, it should
# be noted that these commands could make the overall job
# run longer
##
isi_array()
{
	for ((b=1; b<=$ARRAY_ITERATIONS; b++))
	do
	start_time2=$(date +%s)
####
# Stats collected from isi_for_array
####
		if [ $STATS_DEBUG ]; then echo "isi_for_array isi_cache_stats (File system caching) $(($(date +%s) - start_time2)) seconds";fi
		isi_for_array "{ echo $(date +%m%d%Y_%H%M%S);isi_cache_stats -v } >> $LOCATION/"'`hostname`'".$(date +%m%d%Y_%H%M%S)_cache.out2 &"

		#These sysctls do not exist in v8 also they aren't relevant because NFS is in userspace LWIO now and not kernel
		if [ $ONEFS_VERSION == "v7" ]; then 
			if [ $STATS_DEBUG ]; then echo "isi_for_array sysctl vfs.nfsrv (NFS sysctls) $(($(date +%s) - start_time2)) seconds";fi
			isi_for_array "{ echo $(date +%m%d%Y_%H%M%S);sysctl vfs.nfsrv } >> $LOCATION/"'`hostname`'".$(date +%m%d%Y_%H%M%S)_SYSCTL_NFS.out2 &"
		fi

		if [ $STATS_DEBUG ]; then echo "top output for lwio (lwio cpu utilization per node) $(($(date +%s) - start_time2)) seconds";fi
		isi_for_array  "{ echo $(date +%m%d%Y_%H%M%S);top -H -P -u } >> $LOCATION/"'`hostname`'".$(date +%m%d%Y_%H%M%S)_cpu.out2 &"
		isi_for_array  "{ echo $(date +%m%d%Y_%H%M%S);top -S 30 } >> $LOCATION/"'`hostname`'".$(date +%m%d%Y_%H%M%S)_cpu_top.out2 &"

		if [ $STATS_DEBUG ]; then echo "sysctl kern.proc.all_stacks $(($(date +%s) - start_time2)) seconds";fi
		isi_for_array  "{ echo $(date +%m%d%Y_%H%M%S);sysctl kern.proc.all_stacks } >> $LOCATION/"'`hostname`'".$(date +%m%d%Y_%H%M%S)_kern_proc_all_stacks.out2 &"

		if [ $STATS_DEBUG ]; then echo "Session List $(($(date +%s) - start_time2)) seconds";fi
		isi_for_array  "{ echo $(date +%m%d%Y_%H%M%S);echo "Session List:"; isi smb sessions list | grep "Total"; } >> $LOCATION/"'`hostname`'".$(date +%m%d%Y_%H%M%S)_session_list.out2 &"
			
		if [ $STATS_DEBUG ]; then echo "SMB Open File List $(($(date +%s) - start_time2)) seconds";fi
		isi_for_array  "{ echo $(date +%m%d%Y_%H%M%S);echo "File List: ";isi smb openfiles list | grep "Total"; } >> $LOCATION/"'`hostname`'".$(date +%m%d%Y_%H%M%S)_file_list.out2 &"

		if [ $STATS_DEBUG ]; then echo "NFS NLM Lists $(($(date +%s) - start_time2)) seconds";fi
		if [ $ONEFS_VERSION == "v7" ]; then
			isi_for_array  "{ echo $(date +%m%d%Y_%H%M%S);echo "Lock List: ";isi nfs nlm locks list | grep "Total"; } >> $LOCATION/"'`hostname`'".$(date +%m%d%Y_%H%M%S)_nfs_nlm_list.out2 &"
			isi_for_array  "{ echo $(date +%m%d%Y_%H%M%S);echo "Lock Waiter List: ";isi nfs nlm locks waiters | grep "Total"; } >> $LOCATION/"'`hostname`'".$(date +%m%d%Y_%H%M%S)_nfs_nlm_list.out2 &"
			isi_for_array  "{ echo $(date +%m%d%Y_%H%M%S);echo "Sessions List: ";isi nfs nlm sessions list | grep "Total"; } >> $LOCATION/"'`hostname`'".$(date +%m%d%Y_%H%M%S)_nfs_nlm_list.out2 &"
		fi
		if [ $ONEFS_VERSION == "v8" ]; then
			isi_for_array  "{ echo $(date +%m%d%Y_%H%M%S);echo "Clients List: ";isi_classic nfs clients list; } >> $LOCATION/"'`hostname`'".$(date +%m%d%Y_%H%M%S)_nfs_nlm_list.out2 &"
			isi_for_array  "{ echo $(date +%m%d%Y_%H%M%S);echo "Lock List: ";isi nfs nlm locks list;} >> $LOCATION/"'`hostname`'".$(date +%m%d%Y_%H%M%S)_nfs_nlm_list.out2 &"
			isi_for_array  "{ echo $(date +%m%d%Y_%H%M%S);echo "Lock Waiter List: ";isi nfs nlm locks waiters; } >> $LOCATION/"'`hostname`'".$(date +%m%d%Y_%H%M%S)_nfs_nlm_list.out2 &"
		fi

		if [ $STATS_DEBUG ]; then echo "checking if debug logging is on $(($(date +%s) - start_time2)) seconds";fi
		if [ $ONEFS_VERSION == "v7" ]; then
		isi_for_array "{ echo $(date +%m%d%Y_%H%M%S);echo lwio Logging:;isi smb log-level;echo lsass Logging:;isi auth log-level; } >> $LOCATION/"'`hostname`'".$(date +%m%d%Y_%H%M%S)_log_level.out2 &"
		fi
		if [ $ONEFS_VERSION == "v8" ]; then
		isi_for_array "{ echo $(date +%m%d%Y_%H%M%S);echo lwio Logging:;isi smb log-level view;echo lsass Logging:;isi auth log-level view;echo nfs Logging:;isi nfs log-level view; } >> $LOCATION/"'`hostname`'".$(date +%m%d%Y_%H%M%S)_log_level.out2 &"
		fi

#		The lines below to check nfs log level for 7.2 cause a unary error, so they have been removed.
#		if [ $ONEFS_VARIANT == "v7.2" ]; then
#		isi_for_array "{ echo $(date +%m%d%Y_%H%M%S);echo nfs Logging:;isi nfs log-level view; } >> $LOCATION/"'`hostname`'".$(date +%m%d%Y_%H%M%S)_log_level.out2 &"
#               fi
	
		if [ $STATS_DEBUG ]; then echo "Gathering netstat commands $(($(date +%s) - start_time2)) seconds";fi
		isi_for_array "{ echo $(date +%m%d%Y_%H%M%S);netstat -na; } >> $LOCATION/"'`hostname`'".$(date +%m%d%Y_%H%M%S)_netstat_na.out2 &"
		isi_for_array "{ echo $(date +%m%d%Y_%H%M%S);netstat -in; } >> $LOCATION/"'`hostname`'".$(date +%m%d%Y_%H%M%S)_netstat_in.out2 &"
		isi_for_array "{ echo $(date +%m%d%Y_%H%M%S);netstat -s; } >> $LOCATION/"'`hostname`'".$(date +%m%d%Y_%H%M%S)_netstat_s.out2 &"

		if [ $STATS_DEBUG ]; then echo "checking memory utilization $(($(date +%s) - start_time2)) seconds";fi
		isi_for_array "{ echo $(date +%m%d%Y_%H%M%S);echo lwio Memory:;ps uaxfwww | grep lwio|grep -v grep;echo lsass Memory:;ps uaxfwww | grep lsass|grep -v grep;echo SrvSvc Memory:;ps uaxfwww | grep 's[r]vsvc'|grep -v grep; echo nfs Memory:; ps uaxfwww|grep nfs|grep -v grep } >> $LOCATION/"'`hostname`'".$(date +%m%d%Y_%H%M%S)_process_memory.out2 &"

		if [ $STATS_DEBUG ]; then echo "Gathering User ID Mapping statistics $(($(date +%s) - start_time2)) seconds";fi
		isi_for_array "{ echo $(date +%m%d%Y_%H%M%S);sysctl efs.idmap.stats  } >> $LOCATION/"'`hostname`'".$(date +%m%d%Y_%H%M%S)_IDMapping.out2 &"

#######
# Step 1: Adding additional isi_for_array stats
# Add additional stats here in the following format:
# isi_for_array '{ echo $(date +%m%d%Y_%H%M%S);isi_cache_stats -v } >> $LOCATION/"'`hostname`'".$(date +%m%d%Y_%H%M%S)_cache.out2 &'
# Goto Step 2.
#######
		finish_time2=$(date +%s)
		TOTAL_ARRAY_DELAY=$((finish_time2 - start_time2))
		if (( $TOTAL_ARRAY_DELAY <= $ARRAY_DELAY )); then
			sleep $((ARRAY_DELAY - TOTAL_ARRAY_DELAY ))
			TOTAL_ARRAY_DELAY=$ARRAY_DELAY
		fi

		if [ $STATS_DEBUG ]; then echo "isi_for_array statistics iteration: $b is done and ran for $TOTAL_ARRAY_DELAY seconds.";fi
done
####
# isi for array stats file merger
####
	if [ $ONEFS_VERSION == "v7" ]; then isi_for_array "cat $LOCATION/"'`hostname`'".*_SYSCTL_NFS.out2 > $LOCATION/"'`hostname`'".NFS.sysctls.txt";fi
	isi_for_array "cat $LOCATION/"'`hostname`'".*_cache.out2 > $LOCATION/"'`hostname`'".GENERAL.cache.txt"
	isi_for_array "cat $LOCATION/"'`hostname`'".*_cpu.out2 > $LOCATION/"'`hostname`'".GENERAL.cpu.txt"
	isi_for_array "cat $LOCATION/"'`hostname`'".*_cpu_top.out2 > $LOCATION/"'`hostname`'".GENERAL.cpu_top.txt"
	isi_for_array "cat $LOCATION/"'`hostname`'".*_kern_proc_all_stacks.out2 > $LOCATION/"'`hostname`'".GENERAL.kern_proc_all_stacks.txt"
	isi_for_array "cat $LOCATION/"'`hostname`'".*_session_list.out2 > $LOCATION/"'`hostname`'".SMB.session_list.txt"
	isi_for_array "cat $LOCATION/"'`hostname`'".*_file_list.out2 > $LOCATION/"'`hostname`'".SMB.file_list.txt"
	isi_for_array "cat $LOCATION/"'`hostname`'".*_nfs_nlm_list.out2 > $LOCATION/"'`hostname`'".NFS.nlm_list.txt"
	isi_for_array "cat $LOCATION/"'`hostname`'".*_log_level.out2 > $LOCATION/"'`hostname`'".SMB.log_level.txt"
	isi_for_array "cat $LOCATION/"'`hostname`'".*_netstat_na.out2 > $LOCATION/"'`hostname`'".NETWORK.netstat_na.txt"
	isi_for_array "cat $LOCATION/"'`hostname`'".*_netstat_in.out2 > $LOCATION/"'`hostname`'".NETWORK.netstat_in.txt"
	isi_for_array "cat $LOCATION/"'`hostname`'".*_netstat_s.out2 > $LOCATION/"'`hostname`'".NETWORK.netstat_s.txt"
	isi_for_array "cat $LOCATION/"'`hostname`'".*_process_memory.out2 > $LOCATION/"'`hostname`'".GENERAL.service_memory.txt"
	isi_for_array "cat $LOCATION/"'`hostname`'".*_IDMapping.out2 > $LOCATION/"'`hostname`'".GENERAL.idmap_stats.txt"
#######
# Step 2: Adding additional isi_for_array stats
# Add a cat statement for the stat added
# in Step 1 in the following format:
# isi_for_array -s 'cat $LOCATION/"'`hostname`'".*_lwio_cpu.out2 > $LOCATION/"'`hostname`'".lwio_cpu.txt'
#######
	find $LOCATION -type f -iname "*.out2" -exec rm -f {} +;
	echo 1 > $LOCATION/array_done.tmp2
	if [ -f $LOCATION/stats_done.tmp1 -a -f $LOCATION/array_done.tmp2 ]; then
		post_processing
	else
		echo "isi_for_array stats done, waiting on isi stats to complete."
	fi
}

pre_processing
isi_stats &
isi_array &
