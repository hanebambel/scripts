#!/bin/bash
#
# Author: SIFTU
# Version: 1.4
#
# Usage: nas_powerdown <sleep_packets>
#
# This is scheduled in CRON.  Schedule it to run at regular intervals i.e. 15,30,60 mins 
# It compares the RX and TX packets from the previous run
# ago to detect if they significantly increased past the number of sleep packets.
# If they haven't, it will force the system to sleep.
#
# Notes: * Be sure to supply the sleep packets as an argument. if less packets than that has been recieved on the
#	   interface since the last run the system will shutdown. A rough guide is 1000 packets per 15 mins
#	 * optional arguments are -e for email and -h for hibernate
# 	 * The system will not shutdown if a ZFS scrub or a resilver is in progress
#
# Todo: Add support for DHCP interfaces

log="/mnt/zpool1/Data/tmp/log/idle.log"
stats_file="/mnt/zpool1/Data/tmp/log/nas_stats.log"
csv_file="/mnt/zpool1/Data/tmp/log/network.csv"

# Find out if it s embedded or full install
#if [[ $(grep embedded /etc/platform) ]]; then
#    config="/cf/conf/config.xml"  # For embedded installs
#    # Add a test to remount /cf if there is problems
#    if [[ ! -f $config ]]; then 
#        umount /cf && mount /cf
#    fi
#else
#    config="/conf/config.xml"  # For full installs
#fi

## Find the LAN interface
#ip=$(/usr/local/bin/xml sel -t -v "//interfaces/lan/ipaddr" $config)
ip="192.168.2.10"
interface=$(netstat -in|grep $ip|awk '{print $1}')

if [[ -z $ip || -z $interface ]]; then
    echo "Could not determine ip: $ip or interface: $interface or could not find the config file: $config"
    exit 1
fi

## Only works if smartd has a valid email set in SMART
#email_to=$(/usr/local/bin/xml sel -t -v "//smartd/email/to" $config)
#email_from=$(/usr/local/bin/xml sel -t -v "//email/from" $config)
#subject="$(hostname -s) - Shutdown - $(date +%H:%M\ %Y-%m-%d)"

sleep_packets="$1"

process_args()
{
if [[ -z "$1" ]]; then
	echo "Usage: nas_poweroff.sh <sleep packets> [-h -e]"
	echo "The following flags are optional"
	echo "	-e - send email when shutdown occurs"
	echo "	-h - hibernate instead of shutdown (acpiconf -s3)"
	exit 1
fi
hibernate="n"; email="n"
#for ARG in "$@"
#      do
#       case $ARG in
#            "-e" ) email="y";;
#            "-h" ) hibernate="y";;
#       esac
#done
}

process_args "$@"

# Extract the current values of RX/TX
rx=$(netstat -n -I $interface|grep $ip|awk {'print $5'})
tx=$(netstat -n -I $interface|grep $ip|awk {'print $8'})

#Write Date to log
echo "Current Values - $(date)" >> $log
echo -e "rx: $rx tx: $tx\n" >> $log

# Check if scrub is going
if [[ $(zpool status|grep "in progress") ]]; then
        scrub=1
    else
        scrub=0
fi

# Check if MacBook is connected
if [[ $(netstat|grep -e "Jans-MBP" -e "MacBookProM3Max") ]]; then
        connected=1
    else
        connected=0
fi


# Check if RX/TX Files Exist
if [[ -f $stats_file ]]; then
	read -r p_rx p_tx <<< $(cat $stats_file)
	echo "Previous Values" >> $log
	echo "p_rx: $p_rx t_rx: $p_tx" >> $log
	echo "$rx $tx" > $stats_file    ## Write packets to stats file
	
	# Calculate threshold limit 
	t_rx=$(($p_rx + $sleep_packets))
	t_tx=$(($p_tx + $sleep_packets))

	echo "Threshold Values" >> $log
	echo -e "t_rx: $t_rx t_tx: $t_tx\n" >> $log
    
    # Write csv-file
    echo -e "$(date);$rx;$tx\n" >> $csv_file

	if [[ $rx -le $t_rx ]] && [[ $tx -le $t_tx ]]; then  ## If network packets have not changed that much
		echo " " >> $log
		rm $stats_file 
        	if [[ $scrub -eq 0 ]]; then
				if [[ $connected -eq 0 ]]; then
	            	if [[ $email == "y" ]]; then 
						diff_rx=$((rx-p_rx))
						diff_tx=$((tx-p_tx))
						body="$(hostname -s) recieved $diff_rx and transmitted $diff_tx packets which is less than the threshold of $1 packets on the interface $interface. Shutting down"
						printf "From:$email_from\nTo:$email_to\nSubject:$subject\n\n$body" | /usr/local/bin/msmtp --file=/var/etc/msmtp.conf -t
		    			sleep 20 ## Give time for the email to be sent
		    		fi
		    		if [[ $hibernate == "y" ]]; then
                		rm $stats_file
			    		acpiconf -s3 		## Go into S3.
		    		else	
   		    			shutdown -p now 	## Force shutdown
		    		fi
				fi
        	fi
	fi
#If RX/TX Files Doesn't Exist
else 
	echo "$rx $tx" > "$stats_file" ## Write packets to file
	touch "$log"
fi

exit 0
