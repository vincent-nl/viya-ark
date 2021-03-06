#!/bin/bash
####################################################################
#### Author: SAS Institute Inc.                                 ####
####################################################################
#
# Used to start/stop/check SAS Viya Services
#

do_usage()
{
	echo "Usage: This script is used internally by SAS Viya-ARK MMSU playbooks."
}

do_stopms()
{
	LIST=$(ls sas-viya-* 2>/dev/null|grep -v cascontroller)
	do_stop
}

do_stopmt()
{
	LIST=$(ls sas-*-all-services 2>/dev/null)
	do_stop
}

do_stopcas()
{
	LIST=$(ls sas-*-cascontroller-default 2>/dev/null)
	do_stop
}
do_stop()
{
	NLIST=
	for p in $LIST
	do
		if [[ $p =~ -viya-all-services|-consul-|-vault-|-httpproxy-|-rabbitmq-|-sasdatasvrc- ]]; then
			continue
		fi
		NLIST="$p $NLIST"
	done

	LIST=$NLIST
	do_ps_common stop
}

do_startmt()
{
	LIST=$(ls sas-*-all-services 2>/dev/null| grep -v '\-viya\-')
	do_start_common
}

do_startcas()
{
	LIST=$(ls sas-*-cascontroller-default 2>/dev/null)
	do_start_common
}

do_start_common()
{
	do_ps_common start
}

do_ps_common()
{
	ACTION=$1
	LIST=$(echo $LIST)

        if [[ "$LIST" == "" ]]; then
                return 0
        fi

	if [[ "$DEBUG" != "" ]]; then
		echo "viyasvs: LIST=($LIST)"
		return 0
	fi

	for p in $LIST
	do
		#echo "viyasvs: $ACTION $p"
		if [[ $p =~ -all-services ]]; then
			/etc/init.d/$p $ACTION &
		else
			do_service $ACTION $p
		fi
	done

	for job in $(jobs -p)
	do
		if [[ -e /proc/$job ]]; then
			wait $job || let "FAIL+=1"
		fi
	done

	if [[ $FAIL -gt 0 ]]; then
		echo "ERROR: service $ACTION failed"
		return $FAIL
	fi
}

do_service()
{
	mode=$1
	shift 1
	service=$*

	if [[ "$DEBUG" != "" ]]; then
		echo "viyasvs: systemctl $mode $service"
		return 0
	fi

	if [[ "${SYSTYPE}" == "systemd" ]]; then
		systemctl $mode $service &
	else
		service $service $mode &
	fi
	return $!
}

do_svastatus()
{
	CMD=/etc/init.d/sas-viya-consul-default
	if [[ ! -x $CMD ]]; then
		echo "ERROR: Could not find the service $CMD"
		exit 2
	fi

	info=$($CMD status 2>&1)
	rc=$?
	if [[ $rc != 0 ]]; then
		echo $info|grep -q 'is stopped'
		if [[ $? == 0 ]]; then
			echo "Consul is down - unable to obtain status"
			return
		else
			echo "$info"
			exit $rc
		fi
	fi

	LIST=$(ls sas-*-all-services 2>/dev/null)

	for f in $LIST
	do
		/etc/init.d/$f status|sed "s|sas-services completed|$f completed|"
	done
	return 0
}

do_checkdb()
{
	if [[ "$viya35" == "1" ]]; then
		CMD=/etc/init.d/sas-viya-sasdatasvrc-${dbname}-pgpool${dbnum}
	else
		CMD=/etc/init.d/sas-viya-sasdatasvrc-${dbname}
	fi
	if [[ ! -x $CMD ]]; then
		echo "Warning: Could not find the service $CMD"
		#exit 2
		return
	fi

	info=$($CMD status 2>&1)
	rc=$?
	echo "$info"
	if [[ $rc != 0 ]]; then
		exit $rc
	fi
}

do_startdb()
{
	if [[ "$viya35" == "1" ]]; then
		dbnum=$dbarg2
		if [[ -x "$DBDIR/pgpool${dbnum}/startall" ]]; then
			if [[ "$DEBUG" == "" && "$dbnum" == "0" ]]; then
				check_consul
				if [[ $? == 0 ]]; then
					#status: is running not sufficient
					dbstatus=$(/etc/init.d/sas-viya-sasdatasvrc-${dbname}-pgpool${dbnum} status|grep 'node_id')
					if [[ "$dbstatus" == "" ]]; then
						su - sas -c "$DBDIR/pgpool${dbnum}/startall"
						FAIL=$?
					fi
				else
					echo "ERROR: consul has issue, need to be fixed before starting pgpool"
					exit 1
				fi
			fi
		fi
	else
		if [[ -f "sas-viya-sasdatasvrc-${dbname}" ]]; then
			LIST="
			sas-viya-sasdatasvrc-${dbname}-pgpool0-ct-pcp
			sas-viya-sasdatasvrc-${dbname}-pgpool0-ct-pgpool
			sas-viya-sasdatasvrc-${dbname}-pgpool0-ct-pool_hba
			sas-viya-sasdatasvrc-${dbname}
			"
			do_ps_common start
		fi
	fi
}

do_stopdb()
{
	if [[ "$viya35" == "1" ]]; then
		dbnum=$dbarg2
		if [[ -x "$DBDIR/pgpool${dbnum}/shutdownall" ]]; then
			if [[ "$DEBUG" == "" && "$dbnum" == "0" ]]; then
				check_consul
				if [[ $? == 0 ]]; then
					dbstatus=$(/etc/init.d/sas-viya-sasdatasvrc-${dbname}-pgpool${dbnum} status|grep 'is running')
					if [[ "$dbstatus" != "" ]]; then
						su - sas -c "$DBDIR/pgpool${dbnum}/shutdownall"
						FAIL=$?
					fi
				else
					echo "Warning: consul is not up, skip shutdown pgpool"
					exit 0
				fi
			fi
		fi
	else
		if [[ -f "sas-viya-sasdatasvrc-${dbname}" ]]; then
			LIST="
			sas-viya-sasdatasvrc-${dbname}
			sas-viya-sasdatasvrc-${dbname}-pgpool0-ct-pool_hba
			sas-viya-sasdatasvrc-${dbname}-pgpool0-ct-pgpool
			sas-viya-sasdatasvrc-${dbname}-pgpool0-ct-pcp
			"
		fi
	fi

	do_ps_common stop
}

check_dbps()
{
	for f in $LIST
	do
		skip=0
		if [[ -f "$PIDROOT/$f.pid" ]]; then
			p=$(cat $PIDROOT/$f.pid)
			ps -p $p > /dev/null 2>&1
			if [[ $? == 0 ]]; then
				skip=1
			fi
		fi
		if [[ "$skip" != "1" ]]; then
			rc=$(do_service stop $f)
			if [[ "$rc" != "0" ]]; then
				wait $rc
			fi
		fi
	done
}

do_startdbct()
{
	if [[ "$viya35" == "1" ]]; then
		dbtype=$dbarg2
		LIST1=$(find . -name "sas-viya-sasdatasvrc-${dbname}-${dbtype}*-consul-template-operation_node"| cut -c3-|sort)
		LIST2=$(find . -name "sas-viya-sasdatasvrc-${dbname}-${dbtype}*-consul-template-*_hba"| cut -c3-|sort)
		LIST="$LIST1 $LIST2"
		check_dbps
		do_ps_common start
		if [[ "$dbtype" == "node" && -x "$DBDIR/node0/startall" ]]; then
			if [[ "$DEBUG" == "" && "$dbnum" == "0" ]]; then
				check_consul
				if [[ $? == 0 ]]; then
					dbstatus=$(/etc/init.d/sas-viya-sasdatasvrc-${dbname}-node0 status|grep 'is running')
					if [[ "$dbstatus" == "" ]]; then
						su - sas -c "$DBDIR/node0/startall"
						if [[ $? != 0 ]]; then
							let "FAIL+=1"
						fi
					fi
				else
					echo "ERROR: consul has issue, need to be fixed before starting nodes"
					exit 1
				fi
			fi
		fi
	else
		LIST=$(find . -name "sas-viya-sasdatasvrc-${dbname}-node*-ct-*"| cut -c3-)
		do_ps_common start
	fi

}

do_stopdbct()
{
	if [[ "$viya35" == "1" ]]; then
		dbtype=$dbarg2
		if [[ "$dbtype" == "node" && -x "$DBDIR/node0/shutdownall" ]]; then
			if [[ "$DEBUG" == "" ]]; then
				check_consul
				if [[ $? == 0 ]]; then
					dbstatus=$(/etc/init.d/sas-viya-sasdatasvrc-${dbname}-node0 status|grep 'is running')
					if [[ "$dbstatus" != "" ]]; then
						su - sas -c "$DBDIR/node0/shutdownall"
						if [[ $? != 0 ]]; then
							let "FAIL+=1"
						fi
					fi
				else
					echo "Warning: consul is not up, skip stopping database nodes"
					exit 0
				fi	
			fi
		fi
		LIST1=$(find . -name "sas-viya-sasdatasvrc-${dbname}-${dbtype}[[:digit:]]*-consul-template-operation_node"| cut -c3-|sort)
		LIST2=$(find . -name "sas-viya-sasdatasvrc-${dbname}-${dbtype}[[:digit:]]*-consul-template-*_hba"| cut -c3-|sort)
		LIST="$LIST2 $LIST1"
		do_ps_common stop
	else
		LIST=$(find . -name "sas-viya-sasdatasvrc-${dbname}-node*-ct-*"| cut -c 3-)
		do_ps_common stop
	fi
}

checkspace()
{
	if [[ ! -d "$DIR" ]]; then
		return
	fi
	FREE=$(($(stat -f --format="%a*%S" "$DIR")))
	
	if [[ "$FREE" -lt "$SIZE" ]]; then
		echo "ERROR: log directory does not have enough free space: $DIR"
		echo "ERROR: free space: $FREE, minimum requirement: $SIZE"
		exit 1	
	fi
}

clean_dbps()
{
	LIST=$(ps -e -o "user pid ppid cmd" |grep -E 'sds_consul_health_check|sas-crypto-management'|grep -v grep)
	NLIST=$(echo "$LIST"|awk '{printf "%s ",$2}')

	for p in $NLIST
	do
		echo "kill -KILL $p"
		kill -KILL $p 2>/dev/null
	done
	return 0
}

do_cleanps()
{
	NLIST=$(echo "$LIST"|awk '{printf "%s ",$2}')

	for p in $NLIST
	do
		echo "kill -KILL $p"
		kill -KILL $p 2>/dev/null
	done
	return 0
}

do_geturls()
{
	FILE=
	host=$(hostname -f)
	if [[ -f /etc/httpd/conf.d/proxy.conf ]]; then
		FILE=/etc/httpd/conf.d/proxy.conf
	elif [[ -f /etc/apache2/conf.d/proxy.conf ]]; then
		FILE=/etc/apache2/conf.d/proxy.conf
	fi
	if [[ "$FILE" == "" ]]; then
		echo "No SAS Viya URLs found"
	else
		if [[ "$HURL" == "" ]]; then
			HURL="http"
		fi
		cat $FILE|grep 'ProxyPass '|egrep -e "/SAS|/ModelStudio"|awk "{print \$2}"|sort|uniq|sed "s/^/${HURL}:\/\/"$host"/"
	fi
	return 0
}

initdb()
{
	ls sas-viya-sasdatasvrc-*consul-template-operation_node > /dev/null 2>&1
	if [[ $? == 0 ]]; then
		viya35=1
		DBDIR=/opt/sas/viya/config/data/sasdatasvrc/$dbname
	else
		viya35=
	fi
}

check_consul()
{
	CMD=/etc/init.d/sas-viya-consul-default
	if [[ ! -x "$CMD" ]]; then
		echo "ERROR: command not found: $CMD"
		exit 2
	fi

	$CMD status|grep -q 'is dead' 
	if [[ $? == 0 ]]; then
		return 255
	fi
	
	CONF=/opt/sas/viya/config/consul.conf
	if [[ ! -f "$CONF" ]]; then
		echo "ERROR: consul config file is missing ($CONF)"
		exit 1
	fi

	source $CONF
	local info
	info=$(/opt/sas/viya/home/bin/consul members)
	rc=$?
	if [[ $rc != 0 ]]; then
		echo "ERROR: consul has error, please check consul log."
		exit $rc
		#return $rc
	fi

	local cnt
	cnt=$(echo "$info"| grep -v -E 'Status|alive'|wc -l)
	if [[ $cnt != 0 ]]; then
		echo "$info"
		echo "ERROR: consul is not healthy, please check consul log."
		exit $cnt
		#return $cnt 
	fi

	/opt/sas/viya/home/bin/sas-csq list-services | grep -q $dbname
	rc=$?
	if [[ $rc != 0 ]]; then
		echo "ERROR: consul has error, database $dbname service is missing: $rc"
		exit $rc
		#return $rc
	fi
}

init()
{
	SYSTYPE=$(ps -p 1|grep -v PID|awk '{print $4}')
	DEBUG=
	LIST=
	cd /etc/init.d
	PIDROOT=/var/run/sas
}
######
# main
######

OPT=$1
init

case "$OPT" in
	stopms|stopmt|startmt|startcas|stopcas|svastatus)
		FAIL=0; do_$OPT; exit $FAIL ;;
	startdbct|startdb|stopdb|stopdbct)
		shift 1
		dbname=$1
		dbarg2=$2
		initdb
		FAIL=0; do_$OPT; exit $FAIL ;;
	checkdb)
		shift 1
		dbname=$1
		dbnum=$2
		initdb
		do_$OPT; exit $? ;;
	start|stop)
		shift 1
		TLIST=$*
		LIST=
		for l in $TLIST
		do
			if [[ -x "/etc/init.d/$l" ]]; then
				LIST="$l $LIST"
			fi
		done

		do_ps_common $OPT

		if [[ "$TLIST" =~ "sas-viya-consul-default" ]]; then
			clean_dbps
		fi
		;;
	cleanps)
		LIST=$(ps -e -o "user pid ppid cmd"|grep -E '/opt/sas/spre/|/opt/sas/viya/'|grep -v -E 'grep|pgpool|postgres')
		do_cleanps
		;;
	cleancomp)
		LIST=$(ps -e -o "user pid ppid cmd" |grep -E '/opt/sas/spre/|/opt/sas/viya/'|grep compsrv|grep -v grep)
		do_cleanps
		;;
	checkspace)
		DIR=$2; SIZE=$3
		$OPT; exit $? ;;
	geturls)
		HURL=$2
		do_$OPT
		;;
	checkps)
		shift 1
		CNT=$*
		if [[ $CNT -eq 0 ]]; then
			ps -ef|grep -E '/opt/sas/spre/|/opt/sas/viya/|pgpool|postgres'|grep -v grep|awk '{print}'
		else
			info=$(ps -ef|grep -E '/opt/sas/spre/|/opt/sas/viya/|pgpool|postgres'|grep -v grep)
			if [[ "$info" == "" ]]; then
				exit 0
			fi
			total=$(echo "$info"|wc -l)
			if [[ $CNT -ne 1 && $total -gt $CNT ]]; then
				echo "Partial of the processes listed: $CNT/$total"
			fi
			echo "$info" | tail -$CNT
		fi
		exit 0
		;;
	*)
		do_usage; exit 1 ;;
esac
