#!/bin/bash

usage() { echo "Usage: $0 [-s] imagefile.img [newimagefile.img]"; exit -1; }

should_skip_autoexpand=false

while getopts ":s" opt; do
  case "${opt}" in
    s) should_skip_autoexpand=true ;;
    *) usage ;;
  esac
done
shift $((OPTIND-1))

#Args
img=$1

#Usage checks
if [[ -z $img ]]; then
  usage
fi
if [[ ! -e $img ]]; then
  echo "ERROR: $img is not a file..."
  exit -2
fi
if (( EUID != 0 )); then
  echo "ERROR: You need to be running as root."
  exit -3
fi

#Check that what we need is installed
A=`which parted 2>&1`
if (( $? != 0 )); then
  echo "ERROR: parted is not installed."
  exit -4
fi

#Copy to new file if requested
if [ -n "$2" ]; then
  echo "Copying $1 to $2..."
  cp --reflink=auto --sparse=always "$1" "$2"
  if (( $? != 0 )); then
    echo "ERROR: Could not copy file..."
    exit -5
  fi
  img=$2
fi

#Gather info
beforesize=`ls -lah $img | cut -d ' ' -f 5`
partnum=`parted -m $img unit B print | tail -n 1 | cut -d ':' -f 1 | tr -d '\n'`
partstart=`parted -m $img unit B print | tail -n 1 | cut -d ':' -f 2 | tr -d 'B\n'`
loopback=`losetup -f --show -o $partstart $img`
currentsize=`tune2fs -l $loopback | grep 'Block count' | tr -d ' ' | cut -d ':' -f 2 | tr -d '\n'`
blocksize=`tune2fs -l $loopback | grep 'Block size' | tr -d ' ' | cut -d ':' -f 2 | tr -d '\n'`

#Check if we should make pi expand rootfs on next boot
if [ "$should_skip_autoexpand" = false ]; then
  #Make pi expand rootfs on next boot
  mountdir=`mktemp -d`
  mount $loopback $mountdir

  if [ `md5sum $mountdir/etc/rc.local | cut -d ' ' -f 1` != "920ba03e3404c3e22f07305d27490bd7" ]; then
    echo Creating new /etc/rc.local
    mv $mountdir/etc/rc.local $mountdir/etc/rc.local.bak
    ###Do not touch the following 6 lines including EOF - unless you change the hash above###
cat <<\EOF > $mountdir/etc/rc.local
#!/bin/bash
FILE=/boot/passwords.txt
if [ -f $FILE ]; then
  echo "You get one shot at updating passwords"
  cat $FILE | chpasswd
  wipe -f $FILE
fi
FILE=/boot/deviceid.txt
if [ -f $FILE ]; then
  echo "I also update hostnames"
  CURRENT_HOSTNAME=`cat /etc/hostname | tr -d " \t\n\r"`
  NEW_HOSTNAME=`cat /boot/deviceid.txt | tr -d " \t\n\r"`
  echo $NEW_HOSTNAME > /etc/hostname
  sed -i "s/127.0.1.1.*$CURRENT_HOSTNAME/127.0.1.1\t$NEW_HOSTNAME/g" /etc/hosts
fi
/usr/bin/raspi-config --expand-rootfs
rm -f /etc/rc.local; cp -f /etc/rc.local.bak /etc/rc.local; reboot
exit 0
EOF
    ###End no touch zone###
    chmod +x $mountdir/etc/rc.local
  fi
  umount $mountdir
else
  echo Skipping autoexpanding process...
fi

#Make sure filesystem is ok
e2fsck -f $loopback
minsize=`resize2fs -P $loopback | cut -d ':' -f 2 | tr -d ' ' | tr -d '\n'`
if [[ $currentsize -eq $minsize ]]; then
  echo ERROR: Image already shrunk to smallest size
  exit -6
fi

#Add some free space to the end of the filesystem
if [[ `expr $currentsize - $minsize - 5000` -gt 0 ]]; then
  minsize=`expr $minsize + 5000 | tr -d '\n'`
elif [[ `expr $currentsize - $minsize - 1000` -gt 0 ]]; then
  minsize=`expr $minsize + 1000 | tr -d '\n'`
elif [[ `expr $currentsize - $minsize - 100` -gt 0 ]]; then
  minsize=`expr $minsize + 100 | tr -d '\n'`
fi

#Shrink filesystem
resize2fs -p $loopback $minsize
if [[ $? != 0 ]]; then
  echo ERROR: resize2fs failed...
  mount $loopback $mountdir
  mv $mountdir/etc/rc.local.bak $mountdir/etc/rc.local
  umount $mountdir
  losetup -d $loopback
  exit $rc
fi
sleep 1

#Shrink partition
losetup -d $loopback
partnewsize=`expr $minsize \* $blocksize | tr -d '\n'`
newpartend=`expr $partstart + $partnewsize | tr -d '\n'`
part1=`parted $img rm $partnum`
part2=`parted $img unit B mkpart primary $partstart $newpartend`

#Truncate the file
endresult=`parted -m $img unit B print free | tail -1 | cut -d ':' -f 2 | tr -d 'B\n'`
truncate -s $endresult $img
aftersize=`ls -lah $img | cut -d ' ' -f 5`

echo "Shrunk $img from $beforesize to $aftersize"
