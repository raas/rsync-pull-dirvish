#!/usr/bin/zsh
# vim: ai
#
# Copy/pull dirvish backup over here, maintaining hardlinks as needed.
# Also delete any images deleted on the remote side.
#
# This script is safe to stop and restart at any time, missed or incomplete
# stuff will be copied again. An already-running script will be detected
# and a second one will not be started.
#
# You need to at least create the vault directories, preferably 'seed' them
# by sneakernet first.
#
# PLEASE do not have spaces in vault or image names, the code will die :)
#
# Andras.Horvath@gmail.com, 2008
#
# requires: rsync, dotlockfile, awk, grep, date, ls, sleep

#------------------------------------ config --
# pull backup from here, over rsync
RSYNC=rsync
FROM=rsync://yggdrasil:1873/backup
# this matches the vault names
VAULTPATTERN="yggdrasil-*"
RSYNC_COPY_CMD="$RSYNC -rltH --delete -pgo --stats -D --numeric-ids -x --compress"

# copy retries
RSYNC_RETRIES=6
RSYNC_SLEEP=30m # thus 6x30m = 3 hours in total

# to here..
TO=/srv/yggdrasil

set -o shwordsplit

#------------------------------------ functions --
# list files in a given remote subdir
# $1 - rsync url
# print: list of files
# 
function rsync_ls() {

	# FIXME error checking..? done outside at the moment
	$RSYNC $1 | while read rights size date time filename; do
		[[ "$filename" != "." ]] && echo "$filename"
	done

	return $?
}

#------------------------------------
# array membership test
# $1: member? of array
# $2+: some array
# return: 1 (false) or 0 (success)
function is_member() {
	__r=1
	__s=$1 ; shift
	for __m in $*; do
		if [[ "$__s" == "$__m" ]] ; then
			__r=0
			break
#		elif [[ "$__s" > "$__m" ]] ; then
#			break
		fi
	done

	return $__r
}

#------------------------------------
# get another reference directory
# since the one in the dirvish job descriptor has been deleted
# this will be the latest older run
# FIXME is it safe to rely on string sorting for this?
#
# $1: old (missing) ref, full path (!)
# return: new ref basename (!), or "__none__" if nothing was found
function get_older_ref() {
	__oldr=${1:t} # basename
	__rval="__none__"
	find ${1:h} -maxdepth 1 -type d ! -name dirvish ! -path ${1:h} | while read __newfp; do
		__newr=${__newfp:t}
		if [[ "$__oldr" > "$__newr" ]] ; then
			__rval=$__newr
		else
			break
		fi
	done
	echo $__rval
}

#------------------------------------
# remote -> local copy with rsync
# hardlinks to previous backup if possible
#
# $1: vault
# $2: image
# 
function rsync_copy() {
		v=$1
		i=$2
		mkdir -p ${TO}/${v}/${i}
		t0rsync=$( date +%s)
		# we copy the 'summary' file in its rightful place right now
		# as we need it now to determine the reference image for this one
		# but for example the 'dirvish' subdir doesn't have a 'summary' file
		# so return code 23 (no such file) is OK here 
		e=255; tries=0
		while [ "$e" -ne 0 ] && [ "$e" -ne 23 ] && [ "$tries" -lt "$RSYNC_RETRIES" ]; do
			echo "rsync_copy: Getting summary for ${v}/${i}, try $tries"
			$RSYNC_COPY_CMD  ${FROM}/${v}/${i}/summary ${TO}/${v}/${i} 2>/dev/null
			e=$?
			if [ "$e" -ne 0 ] && [ "$e" -ne 23 ] ; then
				echo "rsync_copy: failed try (error code $e), sleeping $RSYNC_SLEEP"
				sleep $RSYNC_SLEEP
			fi
			(( tries++ ))
		done
		echo -n "--- Getting summary for ${v}/${i} used $tries tries of $RSYNC_RETRIES and "
		if [ "$e" -eq 0 ]; then echo "SUCCEEDED"; else echo "FAILED ($e)"; fi

		#---- actual transfer ----

		if [ "$e" -eq 0 ] || [ "$e" -eq 23 ] ; then
			REFERENCE=$( awk '/^Reference:/{print $2;exit}' ${TO}/${v}/${i}/summary 2>/dev/null )
			if [[ ! -d ${TO}/${v}/${REFERENCE} ]]; then
				# deleted meanwhile
				# if we don't remedy this, the whole show will be copied!
				# thus let's find a new reference point
				r=$( get_older_ref ${TO}/${v}/$REFERENCE )
				echo "rsync_copy warning: reference ${TO}/${v}/${REFERENCE} is missing, using $r instead"
				REFERENCE=$r
			fi
			e=255; tries=0
			while [ "$e" -ne 0 ] && [ "$tries" -lt "$RSYNC_RETRIES" ]; do
				if [[ ! -z "$REFERENCE" ]]; then
					echo "rsync_copy: Getting data for ${v}/${i}, reference $REFERENCE, try $tries"
					$RSYNC_COPY_CMD \
						--link-dest=${TO}/${v}/${REFERENCE} \
						${FROM}/${v}/${i}/ ${TO}/${v}/${i}
				else
					echo "rsync_copy: Getting data for ${v}/${i}, no reference, try $tries"
					$RSYNC_COPY_CMD \
						--compress \
						${FROM}/${v}/${i}/ ${TO}/${v}/${i}
				fi
				e=$?
				if [ "$e" -ne 0 ] ; then
					echo "rsync_copy: failed try (error code $e), sleeping $RSYNC_SLEEP"
					sleep $RSYNC_SLEEP
				fi
				(( tries++ ))
			done

			echo -n "--- Copy for ${v}/${i} used $tries tries of $RSYNC_RETRIES, took $(( $(date +%s) - $t0rsync )) seconds and "
			if [ "$e" -eq 0 ]; then echo "SUCCEEDED"; else echo "FAILED ($e)"; fi
		fi
		
		return $e
}
#------------------------------------ main --

# check if we're already running

LOCKFILE=/var/run/$( basename "${0}").lock
if ! ( dotlockfile -p -r0 $LOCKFILE ); then
	echo "$0 already running with PID $( cat $LOCKFILE ), please check."
	exit 1
fi

VAULTS=$( rsync_ls $FROM/${VAULTPATTERN} )

if [[ -z "$VAULTS" ]]; then
	echo "No vaults found..."
	exit 1
fi

echo "Starting..."
t0=$( date +%s)
#------------------------------------ BEGIN scan for fresh changes
# we check what's gone and what's to be copied
# then create/update 'todo' entries for ourselves in ${TO}/.todo.${vaultname}
# in case we're interrupted
for v in $VAULTS; do
	tv0=$( date +%s)
	echo "**** VAULT scanning $v starting ****"
	REMOTE_IMAGES=$( rsync_ls "${FROM}/${v}/" )
	if [[ -z "$REMOTE_IMAGES" ]]; then
		echo "No remote images found... this is not good. Unreachable?"
		exit 1
	fi

	LOCAL_IMAGES=$( /bin/ls ${TO}/${v} ) # FIXME find?
	if [[ -z "$LOCAL_IMAGES" ]]; then
		echo "No local images found... this is not good. Not mounted?"
		exit 1
	fi

	DELETE=""
	COPY=""
	for r in ${REMOTE_IMAGES}; do
		if [[ ! -d ${TO}/${v}/${r}/tree ]] ; then
			COPY="$COPY ${r}"
		fi
	done # remote
	for l in ${LOCAL_IMAGES}; do
		if ! ( is_member "${l}" "${REMOTE_IMAGES}" ); then
			DELETE="$DELETE ${l}"
		fi
	done # local
	echo "New Copy $v: $COPY"
	echo "New Delete $v: $DELETE"

	# create 'todo' entries here
	mkdir -p "${TO}/.todo.$v"
	# should there be any unfinished 'copy' requests for images
	# that now are deleted, this will overwrite the request
	# with 'delete'..
	for c in $COPY; do echo "copy" > "${TO}/.todo.${v}/$c" ; done
	for d in $DELETE; do echo "delete" > "${TO}/.todo.${v}/$d" ; done

	echo "**** VAULT scanning $v finished in $(( $(date +%s) - $tv0 )) seconds ****"
done
#------------------------------------ END scan for fresh changes

#------------------------------------ BEGIN actually do changes
# process all 'todo' entries

# delete everything unneeded first, so that we might have enough space
for v in $VAULTS; do
	# override these variables with the left-overs of the previous run
	# will 'basename' these full-path filenames later!
	DELETE=$( fgrep -rl delete ${TO}/.todo.${v} )

	tc0=$( date +%s)
	echo "**** Delete in $v started ****"
	for dd in $DELETE; do
		d=$( basename $dd )
		rm -rf "${TO}/${v}/${d}"
		rm -f "${TO}/.todo.${v}/${d}"
	done
	echo "**** Delete in $v finished in $(( $(date +%s) - $tc0 )) seconds ****"
done

for v in $VAULTS; do
	# override these variables with the left-overs of the previous run
	# will 'basename' these full-path filenames later!
	COPY=$( fgrep -rl copy ${TO}/.todo.${v} )

	echo "**** Copy to $v started ****"
	tc0=$( date +%s)
	for cc in ${COPY}; do
		c=$( basename $cc )
		rsync_copy $v $c
		# only remote todo entry if rsync was successful
		if [ $? -eq 0 ] ; then
			rm -f "${TO}/.todo.${v}/${c}"
		else
			echo "ERROR: ${v}/${c} could not be copied."
		fi
	done
	echo "**** Copy to $v finished in $(( $(date +%s) - $tc0 )) seconds ****"
done
#------------------------------------ END actually do changes

echo "**** finished in $(( $(date +%s) - $t0 )) seconds ****"

# check completion

LEFTOVERS=$( find "${TO}" -maxdepth 2 -type f -path "${TO}/.todo.*" )
if [ -z "$LEFTOVERS" ]; then
	echo "FINAL RESULT: all tasks finished"
else
	echo "FINAL RESULT: some tasks not done"
	for l in $LEFTOVERS; do
		echo -n "$( basename $l ): "; cat $l
	done
fi

# clean up empties
echo -n "Cleaning up empty directories... "
find "$TO" -maxdepth 3 -type d -empty -print0 | xargs rm -rf
echo "done."

dotlockfile -u "$LOCKFILE"

exit 0

# EOT
