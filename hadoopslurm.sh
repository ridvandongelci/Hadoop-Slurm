#!/bin/bash
#SBATCH -p parallel       
#SBATCH --qos=short
#SBATCH --exclusive
#SBATCH -o out.log
#SBATCH -e err.log
#SBATCH --open-mode=append
#SBATCH --cpus-per-task=8
#SBATCH -J hadoopslurm
#SBATCH --time=01:30:00
#SBATCH --mem-per-cpu=1000
#SBATCH --mail-user=user@domain.com
#SBATCH --mail-type=ALL    
#SBATCH -N 1



## Using MapReduce with more number of nodes. using N reducers

TIME_LIMIT=$(((3 * 60 + 55) * 60)) # seconds: should give us a few minutes of cleanup time over the sbatch limit

START_TIME=$(date +%s)

# Utils
function min { [[ $1 -lt $2 ]] && echo $1 || echo $2; }
function withTimeout {
   timeRemaining=$((TIME_LIMIT - $(date +%s) + START_TIME))
   if [[ $timeRemaining -le 0 ]]; then
      ret=124
   else
      timeout -sKILL $((timeRemaining+30)) timeout $timeRemaining "$@"
      ret=$?
   fi
   if [[ $ret = 124 || $ret = 137 ]]; then
      echo "!!! TIMED OUT: $@"
      exit 42
   fi
}

# Fetch command line arguments
out=$(readlink -f $1)
[[ -z "$out" ]] && exit 1
if [[ -e $out ]]; then
   if [[ ! -d $out ]]; then
      echo>&2 "$out is not a directory!"
      exit 1
   fi
   rm -r $out
fi
mkdir -p $out





# Log the remaining output to our directory
exec &>$out/script.log
#Trying local Sata disks
## define the working dir on the compute node
#node_dir="/local/$USER/input"
node_dir="$TMPDIR/hadoop"
## check, if it does not exist, then create one
[ -d $node_dir ] || mkdir $node_dir




# Config for everything
export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java))))


# Hadoop config, part 1: some environment variables, initialize config dir
#
# Separate $HADOOP2_HOME since we can only start HDFS from there with Hadoop 2
export HADOOP_HOME=$HOME/hadoop-2.2.0
export HADOOP_MAPRED_HOME=$HADOOP_HOME
export HADOOP_COMMON_HOME=$HADOOP_HOME
export HADOOP_HDFS_HOME=$HADOOP_HOME
export YARN_HOME=$HADOOP_HOME
export HADOOP_CONF_DIR=$HADOOP_HOME/etc/hadoop/
export YARN_CONF_DIR=$HADOOP_HOME/etc/hadoop/
rm -rf $HADOOP_CONF_DIR
mkdir -p $HADOOP_CONF_DIR
ln -s $HADOOP_HOME/etc/template_hadoop/* $HADOOP_CONF_DIR/
slaveHostsFile=$HADOOP_CONF_DIR/slaves
rm -f $slaveHostsFile




# Get SLURM info about our configuration (hostnames and job ID)
masterHost=$(hostname)
echo $(hostname)
srun --immediate hostname | grep -v $masterHost > $slaveHostsFile
slaveCount=$(wc -l < $slaveHostsFile)
[[ $slaveCount -eq 0 ]] && echo>&2 "Not enough slaves!" && exit 2


#to-do improve.
hosts=$HADOOP_CONF_DIR/hosts
srun --immediate hostname > $hosts


srun --immediate hostname > $HADOOP_CONF_DIR/masters


jobID=$SLURM_JOB_ID

# Hadoop config, part 2: more environment variables, customize config dir
#
#es a lo que me refiero, yo nunca le miro nada, pero tengo acceso a todo, y ella acceso a lo mio, sin problemas. no hay nada que ocultar....

# N.B. it's important that we use /local as our storage directory.
localTemp=$TMPDIR/hadoop-$jobID
export HADOOP_LOG_DIR=$out/logs-hadoop
export HADOOP_IDENT_STRING=$USER-$jobID
export HADOOP_PID_DIR=$localTemp/hadoop-pids
mkdir -p $HADOOP_LOG_DIR $HADOOP_PID_DIR
for f in $HADOOP_HOME/etc/template_hadoop/*-site.xml; do
   f2=$HADOOP_CONF_DIR/$(basename $f)
   rm -f $f2
   sed < $f > $f2 \
   "/\${HADOOP_SLURM/ {
      s/\${HADOOP_SLURM_NAMENODE}/$masterHost/
      s/\${HADOOP_SLURM_JOBTRACKER}/$masterHost/
      s/\${HADOOP_SLURM_DFS_REPLICATION}/$(min 3 $slaveCount)/
      s/\${HADOOP_SLURM_MAP}/$((5*24))/
      s/\${HADOOP_SLURM_REDUCE}/$((5*12))/
      s:\${HADOOP_SLURM_TMP}:$localTemp:
   }"
done

rm -f $HADOOP_CONF_DIR/hadoop-env.sh
echo   "/\${HADOOP_/ {
      s/:${HADOOP_CONF_DIR}:$HADOOP_CONF_DIR:
      s/:${HADOOP_LOG_DIR}:$HADOOP_LOG_DIR:
      s/:${HADOOP_IDENT_STRING}:$HADOOP_IDENT_STRING:
      s/:${HADOOP_PID_DIR}:$HADOOP_PID_DIR:
   }"
   
sed < $HADOOP_HOME/etc/template_hadoop/hadoop-env.sh > $HADOOP_CONF_DIR/hadoop-env.sh \
   "/\${HADOOP_/ {
      s:\${HADOOP_CONF_DIR}:$HADOOP_CONF_DIR:
      s:\${HADOOP_LOG_DIR}:$HADOOP_LOG_DIR:
      s:\${HADOOP_IDENT_STRING}:$HADOOP_IDENT_STRING:
      s:\${HADOOP_PID_DIR}:$HADOOP_PID_DIR:
   }"

#HADOOP CONFDIR SETUP
echo "export HADOOP_CONF_DIR=$HADOOP_CONF_DIR" > $HOME/testsetup

# Make sure everything's dead before we start
for h in  $(cat  $slaveHostsFile); do ssh $h "killall -q -9 java"; done
killall -q -9 java

#Start Hadoop
$HADOOP_HOME/bin/hadoop  namenode -format
$HADOOP_HOME/sbin/hadoop-daemon.sh  start namenode 
$HADOOP_HOME/sbin/hadoop-daemons.sh start datanode 
$HADOOP_HOME/sbin/yarn-daemon.sh  start resourcemanager 
$HADOOP_HOME/sbin/yarn-daemons.sh  start nodemanager 
$HADOOP_HOME/sbin/mr-jobhistory-daemon.sh  start historyserver 

#Check start
srun --immediate jps > $out/jsp-$(hostname).log

# Cleanup function in case we timeout, or if we exit in some other unexpected
# fashion (which shouldn't happen, but it's good to have this for that case as
# well).
#
# Note that this has only 30 seconds (scontrol show config | grep KillWait) to
# complete, so don't try to do too much!
cleanupOnTimeout() {
   $HADOOP_HOME/sbin/mr-jobhistory-daemon.sh stop historyserver 
   $HADOOP_HOME/sbin/yarn-daemons.sh stop nodemanager
   $HADOOP_HOME/sbin/yarn-daemon.sh stop resourcemanager
   $HADOOP_HOME/sbin/hadoop-daemons.sh stop datanode
   $HADOOP_HOME/sbin/hadoop-daemon.sh stop namenode
 

  
   # Really kill Hadoop
   killall -q -9 java
   for host in $(cat $hosts); do ssh $host "killall -q -9 java"; done

   # Clear the temporary directories everywhere
   srun --immediate rm -rf $localTemp
   #srun --immediate rm -rf $localTempHBase
}
trap cleanupOnTimeout EXIT


function testHadoop {
	mkdir $out/testdir
	echo \
	'This is one line
	This is another one' > $out/testdir/test
	$HADOOP_HOME/bin/hadoop dfs -copyFromLocal $out/testdir /in
 	$HADOOP_HOME/bin/hadoop jar $HADOOP_HOME/share/hadoop/mapreduce/hadoop-mapreduce-examples-2.*.jar wordcount /in /out
	$HADOOP_HOME/bin/hadoop dfs -cat /out/* > $out/testdir/result
}

#$HADOOP_HOME/bin/hadoop fs -mkdir /user/$USER
$HADOOP_HOME/bin/hadoop fs -mkdir -p /user/$USER/

if [[ ! -f $HOME/experiment.sh ]]; then
    testHadoop &> $out/experiment.log
else
    $HOME/experiment.sh &> $out/experiment.log
fi



sleep 4h


