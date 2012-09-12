#!/bin/bash

pp() {
	echo -e "\e[00;32m"$1"\e[00m"
}

#########################################
# Configuration.
#########################################

# Cluster information.
source storm_install.conf

# Base config.
BASEDIR=$HOME"/epn"
START_SH=$BASEDIR"/start.sh"
STOP_SH=$BASEDIR"/stop.sh"
HOST=`hostname`

#########################################
# Clean up old installation.
#########################################

cleanup() {
	pp "Cleaning up previous installation..."
	rm -rf $BASEDIR
	mkdir $BASEDIR
	echo "#!/bin/bash" > $START_SH
	chmod +x $START_SH
	echo "#!/bin/bash" > $STOP_SH
	chmod +x $STOP_SH
}

#########################################
# System dependencies.
#########################################

deps() {
	pp "Checking system dependencies..."
	echo
	sudo apt-get install screen daemontools uuid-dev git libtool
	echo
}

#########################################
# ZooKeeper.
#########################################

zookeeper() {
	if [ "$HOST" != "$NIMBUS" ]
	then
		pp "Skipping ZooKeeper installation on all hosts but nimbus!"
		return
	fi

	ZK_VERSION="3.3.6"
	ZK_DIR=$BASEDIR"/zookeeper"
	ZK_CONFIGFILE="zoo.conf"
	ZK_CONF=$ZK_DIR"/"$ZK_CONFIGFILE
	ZK_RUN=$ZK_DIR"/run"
	ZK_PURGE=$ZK_DIR"/purge.sh"
	ZK_DATADIR=$ZK_DIR"/data"
	ZK_TARBALL_URL="http://apache.openmirror.de/zookeeper/zookeeper-"$ZK_VERSION"/zookeeper-"$ZK_VERSION".tar.gz"
	ZK_TARBALL=$ZK_DIR/"zookeeper.tar.gz"
	ZK_INSTALLDIR=$ZK_DIR/"zookeeper-"$ZK_VERSION

	pp "Installing ZooKeeper "$ZK_VERSION" on nimbus host '"$HOST"'..."

	mkdir $ZK_DIR &>/dev/null
	mkdir $ZK_DATADIR &>/dev/null

	pp "Downloading ZooKeeper..."

	wget $ZK_TARBALL_URL -q -O $ZK_TARBALL
	tar xzf $ZK_TARBALL -C $ZK_DIR
	rm $ZK_TARBALL

	pp "Configuring ZooKeeper..."

	# Cluster config.
	cat << EOF > $ZK_CONF
tickTime=2000
dataDir=$ZK_DATADIR
clientPort=2181
initLimit=5
syncLimit=2
server.1=$NIMBUS:2888:3888
EOF

	# This host's id.
	echo "1" > $ZK_DATADIR/myid

	# Run script.
	ZK_CP=$ZK_INSTALLDIR/zookeeper-$ZK_VERSION.jar:$ZK_INSTALLDIR/lib/log4j-1.2.15.jar:$ZK_INSTALLDIR/conf
	cat << EOF > $ZK_RUN
#!/bin/bash
_JAVA_OPTIONS="-Xmx1024M -Xms1024M"
java -cp $ZK_CP org.apache.zookeeper.server.quorum.QuorumPeerMain $ZK_CONFIGFILE
EOF
	chmod +x $ZK_RUN

	# Purge script to cleanup zookeeper log files.
	cat << EOF > $ZK_PURGE
mkdir $ZK_DIR/snap
java -cp $ZK_CP org.apache.zookeeper.server.PurgeTxnLog $ZK_DATADIR $ZK_DIR/snap -n 3
rm -r $ZK_DIR/snap
EOF
	chmod +x $ZK_PURGE

	# Run purge.sh via cron job.
	echo "@hourly $ZK_PURGE" | crontab -

	# Update global start/stop scripts.
	echo "supervise $ZK_DIR &" >> $START_SH
	echo "svc -x $ZK_DIR" >> $STOP_SH
}

#########################################
# Storm dependency: ZeroMQ
#########################################

zeromq() {
	ZMQ_VERSION="2.1.7"
	ZMQ_DIR=$BASEDIR"/zeromq"
	ZMQ_TARBALL_URL="http://download.zeromq.org/zeromq-"$ZMQ_VERSION".tar.gz"
	ZMQ_TARBALL=$ZMQ_DIR"/zeromq.tar.gz"

	pp "Installing ZeroMQ "$ZMQ_VERSION" (storm dependency)..."
	mkdir $ZMQ_DIR

	pp "Downloading ZeroMQ..."
	wget $ZMQ_TARBALL_URL -q -O $ZMQ_TARBALL
	tar zxf $ZMQ_TARBALL -C $ZMQ_DIR
	rm $ZMQ_TARBALL

	pp "Compiling ZeroMQ..."
	echo
	pushd $ZMQ_DIR/zeromq-$ZMQ_VERSION
	./configure && make && sudo make install
	popd
	echo
}

#########################################
# Storm dependency 2: JZMQ,
# Java bindings for ZeroMQ.
#
# This is where things get tricky.
# Despite the warning on nathanmarz' page,
# we use mainline git here, as it compiles
# with the latest autoconf and libtool on
# Ubuntu 12.04.
#########################################

jzmq() {
	JZMQ_DIR=$BASEDIR"/jzmq"
	JZMQ_REPO="https://github.com/zeromq/jzmq.git"
	JZMQ_COMMIT="HEAD"

	pp "Installing JZMQ (Java bindings for ZeroMQ) from Github..."

	git clone -q $JZMQ_REPO $JZMQ_DIR

	pp "Compiling JZMQ..."

	echo
	pushd $JZMQ_DIR
	git checkout $JZMQ_COMMIT
	./autogen.sh && ./configure --with-zeromq=/usr/local/lib && make && sudo make install
	popd
	echo
}

#########################################
# Storm itself.
#########################################

storm() {
	STORM_VERSION="0.8.1"
	STORM_DIR=$BASEDIR"/storm"
	STORM_ZIP_URL="https://github.com/downloads/nathanmarz/storm/storm-"$STORM_VERSION".zip"
	STORM_ZIP=$STORM_DIR"/storm.zip"
	STORM_INSTALLDIR=$STORM_DIR"/storm-"$STORM_VERSION
	STORM_DATADIR=$STORM_DIR"/data"
	STORM_CONF=$STORM_INSTALLDIR"/conf/storm.yaml"
	STORM_RUN=$STORM_DIR"/run"

	pp "Installing Storm "$STORM_VERSION"..."
	mkdir $STORM_DIR >/dev/null
	mkdir $STORM_DATADIR >/dev/null

	pp "Downloading Storm..."
	wget $STORM_ZIP_URL -q -O $STORM_ZIP
	unzip -qq $STORM_ZIP -d $STORM_DIR
	rm $STORM_ZIP

	pp "Configuring Storm..."
	echo "storm.local.dir: \""$STORM_DATADIR"\"" > $STORM_CONF
	echo "storm.zookeeper.servers:" >> $STORM_CONF
	echo " - \""$NIMBUS"\"" >> $STORM_CONF
#	for ((i=0;i<${#NODES[@]};i++))
#	do
#		echo " - \""${NODES[$i]}"\"" >> $STORM_CONF
#	done
	if [ "$HOST" != "$NIMBUS" ]
	then
		echo "nimbus.host: \""$NIMBUS"\"" >> $STORM_CONF
	fi

	# Supervisor directories/scripts + global start/stop scripts.
	# Note: If we're NIMBUS, we run the 'nimbis' action instead.
	if [ "$HOST" = "$NIMBUS" ]; then STORM_ACTION="nimbus"; else STORM_ACTION="supervisor"; fi
	cat << EOF > $STORM_RUN
#!/bin/bash
$STORM_INSTALLDIR/bin/storm $STORM_ACTION
EOF
	chmod +x $STORM_RUN
	echo "supervise $STORM_DIR &" >> $START_SH
	echo "svc -x $STORM_DIR" >> $STOP_SH
}

#########################################
# Main app.
#########################################

PHASES=("cleanup" "deps" "zookeeper" "zeromq" "jzmq" "storm")

execute() {
	case "$1" in
	"0")
		cleanup
		;;
	"1")
		deps
		;;
	"2")
		zookeeper
		;;
	"3")
		zeromq
		;;
	"4")
		jzmq
		;;
	"5")
		storm
		;;
	esac
}

if [ $# -eq 1 ]
then
	if [ "$1" = "all" ]
	then
		# Run everything.
		for ((p=0;p<${#PHASES[@]};p++))
		do
			execute $p
		done

		pp "Installation complete."
		pp "Be sure to carefully read the log."
		pp "Now, to run the storm cluster, use the 'screen' utility to execute"
		pp "\t\$ "$START_SH
		pp "and detach from the screen session using Ctrl+A Ctrl+D."
	else
		execute $1

		pp "Phase installation complete."
	fi
else
	echo "Usage: ./install_storm [number_of_phase] or ./install_storm all"
	echo "Phases:"
	for ((i=0;i<${#PHASES[@]};i++))
	do
		echo -e "\t"$i": "${PHASES[$i]}
	done
fi
