# .bashrc
#
# Runs every time a new bash instance is run

# Source global definitions
if [ -f /etc/bashrc ]; then
	. /etc/bashrc
fi



# User specific aliases and functions
export HADOOP_HOME=$HOME/hadoop-2.2.0
export PIG_HOME=$HOME/pig-0.12.0
export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java))))



