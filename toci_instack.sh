#!/usr/bin/env bash

set -eux

if [ ! -e "$TE_DATAFILE" ] ; then
    echo "Couldn't find data file"
    exit 1
fi

export PATH=/sbin:/usr/sbin:$PATH
source toci_functions.sh

export TRIPLEO_ROOT=/opt/stack/new
mkdir -p $WORKSPACE/logs

# Add temporary reverts and cherrypick's here e.g.
# temprevert <projectname> <commit-hash-to-revert> <bugnumber>
# pin <projectname> <commit-hash-to-pin-to> <bugnumber>
# cherrypick <projectname> <gerrit-refspec>

# https://review.openstack.org/#/c/221411/ Bug #1493442
# Make puppet-glance work again on RedHat distros
cherrypick puppet-glance refs/changes/11/221411/1

# Disable horizon on the overcloud. Bug: #1492416
cherrypick tripleo-heat-templates refs/changes/97/219697/2

# ===== Start : Yum repository setup ====
[ -d $TRIPLEO_ROOT/delorean ] || git clone https://github.com/openstack-packages/delorean.git $TRIPLEO_ROOT/delorean

# Now that we have setup all of our git repositories we need to build packages from them
# If this is a job to test master of everything we get a list of all git repo's
if [ -z "${ZUUL_CHANGES:-}" ] ; then
    echo "No change ids specified, building all projects in $TRIPLEO_ROOT"
    ZUUL_CHANGES=$(find $TRIPLEO_ROOT -maxdepth 2 -type d -name .git -printf "%h ")
fi
ZUUL_CHANGES=${ZUUL_CHANGES//^/ }

# prep delorean
sudo yum install -y docker-io createrepo yum-plugin-priorities yum-utils
sudo systemctl start docker

cd $TRIPLEO_ROOT/delorean
sudo rm -rf data *.sqlite
mkdir -p data

sudo semanage fcontext -a -t svirt_sandbox_file_t "$TRIPLEO_ROOT/delorean/data(/.)?"
sudo semanage fcontext -a -t svirt_sandbox_file_t "$TRIPLEO_ROOT/delorean/scripts(/.)?"
sudo restorecon -R "$TRIPLEO_ROOT/delorean"

MY_IP=$(ip addr show dev eth1 | awk '/inet / {gsub("/.*", "") ; print $2}')

sudo chown :$(id -g) /var/run/docker.sock
# Download a prebuilt build image instead of building on
# Image built as usual then exported using "docker save delorean/centos > centos-$date-$x.tar"
curl http://${PYPIMIRROR}/buildimages/centos-20150921-1.tar | docker load

# We have a custom delorean that uses "docker exec" to reuse the same build
# container for each package, so we need to start the build container now
docker rm -f builder-centos || true

sed -i -e "s%target=.*%target=centos%" projects.ini
sed -i -e "s%reponame=.*%reponame=delorean-ci%" projects.ini
# Remove the rpm install test to speed up delorean (our ci test will to this)
# TODO: and an option for this in delorean
sed -i -e 's%.*installed.*%touch $OUTPUT_DIRECTORY/installed%' scripts/build_rpm.sh

virtualenv venv
./venv/bin/pip install -r requirements.txt
./venv/bin/python setup.py install

# post ci chores to run at the end of ci
SSH_OPTIONS='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=Verbose -o PasswordAuthentication=no'
TARCMD="sudo XZ_OPT=-3 tar -cJf - --exclude=udev/hwdb.bin --exclude=etc/services --exclude=selinux/targeted --exclude=etc/services --exclude=etc/pki /var/log /etc"
function postci(){
    set +e
    if [ -e $TRIPLEO_ROOT/delorean/data/repos/ ] ; then
        # I'd like to tar up repos/current but tar'ed its about 8M it may be a
        # bit much for the log server, maybe when we are building less
        find $TRIPLEO_ROOT/delorean/data/repos -name rpmbuild.log | XZ_OPT=-3 xargs tar -cJf $WORKSPACE/logs/delorean_repos.tar.xz
    fi
    if [ "${HOST_IP}" != "" ] ; then
        # Generate extra state information from the running undercloud
        ssh root@${SEED_IP} /tmp/get_host_info.sh

        # Get logs from the undercloud
        ssh root@${SEED_IP} $TARCMD > $WORKSPACE/logs/undercloud.tar.xz

        # when we ran get_host_info.sh on the undercloud it left the output of nova list in /tmp for us
        for INSTANCE in $(ssh root@${SEED_IP} cat /tmp/nova-list.txt | grep ACTIVE | awk '{printf"%s=%s\n", $4, $12}') ; do
            IP=${INSTANCE//*=}
            NAME=${INSTANCE//=*}
            ssh root@${SEED_IP} su stack -c \"scp $SSH_OPTIONS /tmp/get_host_info.sh heat-admin@$IP:/tmp\"
            ssh root@${SEED_IP} su stack -c \"ssh $SSH_OPTIONS heat-admin@$IP sudo /tmp/get_host_info.sh\"
            ssh root@${SEED_IP} su stack -c \"ssh $SSH_OPTIONS heat-admin@$IP $TARCMD\" > $WORKSPACE/logs/${NAME}.tar.xz
        done
        destroy_vms &> $WORKSPACE/logs/destroy_vms.log
    fi
    return 0
}
trap "postci" EXIT

# build packages
# loop through each of the projects listed in ZUUL_CHANGES if it is a project we
# are capable of building an rpm for then build it.
# e.g. ZUUL_CHANGES=openstack/cinder:master:refs/changes/61/71461/4^opensta...
for PROJFULLREF in $ZUUL_CHANGES ; do

    PROJ=$(filterref $PROJFULLREF)

    # If ci is being run for a change to ci its ok not to have a ci repository
    # We also don't build packages for puppet repositories, we use them from source
    if [ "$PROJ" == "tripleo-ci" ] || [[ "$PROJ" =~ puppet-* ]] ; then
        NO_CI_REPO_OK=1
        if [[ "$PROJ" =~ puppet-* ]] ; then
            # openstack/puppet-nova:master:refs/changes/02/213102/5 -> refs/changes/02/213102/5
            export DIB_REPOREF_${PROJ//-/_}=${PROJFULLREF##*:}
        fi
    fi

    MAPPED_PROJ=$(./venv/bin/python scripts/map-project-name $PROJ || true)
    [ -e data/$MAPPED_PROJ ] && continue
    cp -r $TRIPLEO_ROOT/$PROJ data/$MAPPED_PROJ
    pushd data/$MAPPED_PROJ
    GITHASH=$(git rev-parse HEAD)

    # Set the branches delorean reads to the same git hash as ZUUL has left for us
    for BRANCH in master origin/master ; do
        git checkout -b $BRANCH || git checkout $BRANCH
        git reset --hard $GITHASH
    done
    popd

    ./venv/bin/delorean --config-file projects.ini --head-only --package-name $MAPPED_PROJ --local --build-env DELOREAN_DEV=1 --build-env http_proxy=$http_proxy --info-repo rdoinfo
done

# If this was a ci job for a change to ci then we do not have a ci repository (no packages to build)
# Create a dummy repository file so ci can proceed as normal
if [ "${NO_CI_REPO_OK:-}" == 1 ] ; then
    mkdir -p data/repos/current
    touch data/repos/current/delorean-ci.repo
fi

# kill the http server if its already running
ps -ef | grep -i python | grep SimpleHTTPServer | awk '{print $2}' | xargs kill -9 || true
cd data/repos
sudo iptables -I INPUT -p tcp --dport 8766 -i eth1 -j ACCEPT
python -m SimpleHTTPServer 8766 1>$WORKSPACE/logs/yum_mirror.log 2>$WORKSPACE/logs/yum_mirror_error.log &

# On top of the distro repositories we layer two othere
# 1. A recent version of rdo trunk, we should eventually switch to /current
# 2. Trunk packages we built above, this repo has highest priority
sudo rm -f /etc/yum.repos.d/*delorean*
sudo wget http://trunk.rdoproject.org/centos7/8b/ef/8befab055f74ee9e701e333585defcc022ee32cf_2e30451e/delorean.repo -O /etc/yum.repos.d/delorean.repo
sudo wget http://trunk.rdoproject.org/centos7/current/delorean.repo -O /etc/yum.repos.d/delorean-current.repo
sudo wget http://$MY_IP:8766/current/delorean-ci.repo -O /etc/yum.repos.d/delorean-ci.repo
# rewrite the baseurl in delorean-ci.repo as its currently pointing a http://trunk.rdoproject.org/..
sudo sed -i -e "s%baseurl=.*%baseurl=http://$MY_IP:8766/current/%" /etc/yum.repos.d/delorean-ci.repo

# The repository we have just generated should get priority
sudo sed -i -e 's%priority=.*%priority=1%' /etc/yum.repos.d/delorean-ci.repo
# Followed by delorean current (for a subset of packages)
sudo sed -i -e 's%priority=.*%priority=10%' /etc/yum.repos.d/delorean-current.repo
sudo sed -i 's/\[delorean\]/\[delorean-current\]/' /etc/yum.repos.d/delorean-current.repo
sudo /bin/bash -c "cat <<EOF>>/etc/yum.repos.d/delorean-current.repo

includepkgs=diskimage-builder,openstack-heat,instack,instack-undercloud,openstack-ironic,openstack-ironic-inspector,os-cloud-config,os-net-config,python-ironic-inspector-client,python-tripleoclient,tripleo-common,openstack-tripleo-heat-templates,openstack-tripleo-image-elements,openstack-tuskar-ui-extras,openstack-puppet-modules
EOF"
# Finally the pinned delorean repo has the lowest priority
sudo sed -i -e 's%priority=.*%priority=20%' /etc/yum.repos.d/delorean.repo


# Remove everything installed from a delorean repository (only requred if ci nodes are being reused)
TOBEREMOVED=$(yumdb search from_repo "*delorean*" | grep -v -e from_repo -e "Loaded plugins" || true)
[ "$TOBEREMOVED" != "" ] &&  sudo yum remove -y $TOBEREMOVED
sudo yum clean all

# ===== End : Yum repository setup ====

cd $TRIPLEO_ROOT
sudo yum install -y diskimage-builder instack-undercloud os-apply-config

PRIV_SSH_KEY=$(OS_CONFIG_FILES=$TE_DATAFILE os-apply-config --key ssh-key --type raw)
SEED_IP=$(OS_CONFIG_FILES=$TE_DATAFILE os-apply-config --key seed-ip --type netaddress --key-default '')
SSH_USER=$(OS_CONFIG_FILES=$TE_DATAFILE os-apply-config --key ssh-user --type username)
HOST_IP=$(OS_CONFIG_FILES=$TE_DATAFILE os-apply-config --key host-ip --type netaddress)
ENV_NUM=$(OS_CONFIG_FILES=$TE_DATAFILE os-apply-config --key env-num --type int)

mkdir -p ~/.ssh
echo "$PRIV_SSH_KEY" > ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa
# Generate the public key from the private one
ssh-keygen -y -f ~/.ssh/id_rsa > ~/.ssh/id_rsa.pub
# Ensure there is a newline after the last key
echo >> ~/.ssh/authorized_keys
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys

# Kill any VM's in the test env that we may have started, freeing up RAM
# for other tests running on the TE host.
function destroy_vms(){
    ssh $SSH_USER@$HOST_IP virsh destroy seed_${ENV_NUM} || true
    for i in $(seq 0 14) ; do
        ssh $SSH_USER@$HOST_IP virsh destroy baremetalbrbm${ENV_NUM}_${i} || true
    done
}

# TODO : Remove the need for this from instack-undercloud
ls /home/jenkins/.ssh/id_rsa_virt_power || ssh-keygen -f /home/jenkins/.ssh/id_rsa_virt_power -P ""

# TODO : Fix instack-undercloud so TE_DATAFILE can be absolute
cp $TE_DATAFILE instackenv.json
export TE_DATAFILE=instackenv.json

export ANSWERSFILE=/usr/share/instack-undercloud/undercloud.conf.sample
export UNDERCLOUD_VM_NAME=instack
export ELEMENTS_PATH=/usr/share/instack-undercloud
export DIB_DISTRIBUTION_MIRROR=$CENTOS_MIRROR
export DIB_EPEL_MIRROR=$EPEL_MIRROR

# create DIB environment for puppet variables
echo "export DIB_INSTALLTYPE_puppet_modules=source" > $TRIPLEO_ROOT/puppet.env
for X in $(env | grep DIB.*puppet); do
    echo "export $X" >> $TRIPLEO_ROOT/puppet.env
done

# Build and deploy our undercloud instance
SSHOPTS="-o StrictHostKeyChecking=no -o PasswordAuthentication=no"
disk-image-create --image-size 30 -a amd64 centos7 instack-vm -o $UNDERCLOUD_VM_NAME
destroy_vms
dd if=$UNDERCLOUD_VM_NAME.qcow2 | ssh $SSHOPTS root@${HOST_IP} copyseed $ENV_NUM
ssh $SSHOPTS root@${HOST_IP} virsh start seed_$ENV_NUM

tripleo wait_for -d 5 -l 20 scp /etc/yum.repos.d/delorean* root@${SEED_IP}:/etc/yum.repos.d

# copy in required ci files
cd $TRIPLEO_ROOT
scp puppet.env tripleo-ci/scripts/get_host_info.sh root@$SEED_IP:/tmp/

ssh $SSHOPTS root@${SEED_IP} <<-EOF

set -eux

ip route add 0.0.0.0/0 dev eth0 via $MY_IP
echo "nameserver 8.8.8.8" > /etc/resolv.conf
export http_proxy=$http_proxy
export no_proxy=192.0.2.1,$MY_IP

# Setting up nosync first to abolish time taken during disk io sync's
yum install -y nosync
echo /usr/lib64/nosync/nosync.so > /etc/ld.so.preload

curl -o /etc/yum.repos.d/delorean-deps.repo http://trunk.rdoproject.org/centos7/delorean-deps.repo
# Need to give delorean-deps a lower priority than everything else
sudo sed -i -e 's%priority=.*%priority=30%' /etc/yum.repos.d/delorean-deps.repo
yum install -y yum-plugin-priorities

yum install -y python-tripleoclient

# From here down everything runs as the stack user
dd of=/tmp/runasstack <<-EOS

set -eux

export http_proxy=$http_proxy
export no_proxy=192.0.2.1,$MY_IP,$SEED_IP

# This sets all the DIB_.*puppet variables for undercloud and overcloud installation
source /tmp/puppet.env

# Disable installation of tuskar on the undercloud
cp /usr/share/instack-undercloud/undercloud.conf.sample ~/undercloud.conf
sudo sed -i -e 's/.*enable_tuskar.*/enable_tuskar = false/' ~/undercloud.conf
sudo sed -i -e 's/.*enable_tempest.*/enable_tempest = false/' ~/undercloud.conf

openstack undercloud install

source stackrc

# I'm removing most of the nodes in the env to speed up discovery
# This could be in jq but I don't know how
python -c 'import simplejson ; d = simplejson.loads(open("instackenv.json").read()) ; del d["nodes"][$NODECOUNT:] ; print simplejson.dumps(d)' > instackenv_reduced.json

export DIB_DISTRIBUTION_MIRROR=$CENTOS_MIRROR
export DIB_EPEL_MIRROR=$EPEL_MIRROR
export DIB_YUM_REPO_CONF="/etc/yum.repos.d/delorean.repo /etc/yum.repos.d/delorean-current.repo /etc/yum.repos.d/delorean-ci.repo /etc/yum.repos.d/delorean-deps.repo"

# Ensure our ci repository is given priority over the others when building the image
echo -e '#!/bin/bash\nyum install -y yum-plugin-priorities' | sudo tee /usr/share/diskimage-builder/elements/yum/pre-install.d/99-tmphacks
sudo chmod +x /usr/share/diskimage-builder/elements/yum/pre-install.d/99-tmphacks

# Directing the output of this command to a file as its extreemly verbose
echo "INFO: Check /var/log/image_build.txt for image build output"
openstack overcloud image build --all 2>&1 | sudo dd of=/var/log/image_build.txt
# TODO: remove this when Image create in openstackclient supports the v2 API
export OS_IMAGE_API_VERSION=1
openstack overcloud image upload
openstack baremetal import --json instackenv_reduced.json
openstack baremetal configure boot

# introspection is failing right now, so we will not run it
# TODO(trown) add a non-voting job with introspection on to continue troubleshooting it
# openstack baremetal introspection bulk start

# it takes a bit for nova to update the hypervisor stats, so sleep for a bit to be safe
sleep 60

openstack flavor create --id auto --ram 4096 --disk 40 --vcpus 1 baremetal
openstack flavor set --property "capabilities:boot_option"="local" baremetal
openstack overcloud deploy --templates $DEPLOYFLAGS

# Sanity test we deployed what we said we would
[ "$NODECOUNT" != \\\$(nova list | grep ACTIVE | wc -l | cut -f1 -d " ") ] && echo "Wrong number of nodes deployed" && exit 1

source ~/overcloudrc
nova list

EOS
su -l -c "bash /tmp/runasstack" stack
EOF

exit 0
echo 'Run completed.'
